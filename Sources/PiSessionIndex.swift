import Foundation

// NOTE: `nonisolated async` (no `@concurrent`) is intentional and matches the
// existing per-agent loaders — `loadClaudeEntries`, `loadCodexEntries`,
// `loadOpenCodeEntries`, `loadRovoDevEntries` in `SessionIndexStore.swift`
// all use the same form. Greptile flagged the lack of `@concurrent` on the pi
// helpers (https://github.com/manaflow-ai/cmux/pull/3562#discussion_r3190351731);
// adopting it on Pi alone would diverge from the cross-agent pattern. Any
// change here should land for every parser at once — tracked under #3578.
//
// NOTE: This file lives in the app target rather than a SwiftPM package even
// though most of its logic is pure Foundation. The reason is dependency
// surface: `loadPiEntries` and `extractPiMetadata` rely on `forEachJSONLine`,
// `readFileHead`, `ripgrepMatchingPaths`, `searchMaxFiles`, `headByteCap`,
// `ErrorBag`, and `SessionEntry` — all of which are defined in
// `Sources/SessionIndexStore.swift` and are shared by every per-agent loader
// (Codex / Claude / OpenCode / RovoDev). Extracting only the Pi parser into a
// package would either duplicate ~80 lines of JSONL/rg helpers (drift
// surface) or require lifting the shared layer first.
//
// The right sequence is: (1) move `forEachJSONLine`/`readFileHead`/the rg
// helper into a new `CMUXSessionIndexCore` package, (2) extract each
// per-agent parser one PR at a time. Tracked in #3578. Until then, this
// stays here next to its siblings to avoid divergent JSONL semantics.
extension SessionIndexStore {
    /// Pi's on-disk session layout (JSONL only — no SQL backend, no agent-side
    /// snapshot DB to pre-extract metadata):
    ///
    ///   ~/.pi/agent/sessions/--<encoded-cwd>--/<timestamp>_<uuid>.jsonl
    ///
    /// Each file is JSONL where the first line is a session header
    ///   {"type":"session","version":3,"id":"<uuid>","timestamp":"...","cwd":"..."}
    /// followed by message / model_change / session_info entries (see
    /// pi-coding-agent docs/session-format.md).
    ///
    /// We extract:
    ///   - sessionId (full UUID from the header — `pi --session <uuid>` resumes)
    ///   - cwd (header)
    ///   - title: last `session_info.name` if present, else first user message
    ///     truncated to ~80 chars, else "(untitled)"
    ///   - modified: file mtime (NOT the header timestamp — header is creation
    ///     time; mtime tracks the most recent append, which is what we want
    ///     for sort order)
    ///   - specifics: last `model_change` provider + modelId (so the resume
    ///     command keeps the user's chosen model)
    ///
    /// Files with `version != 3` are skipped (forward-compat against future
    /// pi schema bumps).
    nonisolated static func loadPiEntries(
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int,
        errorBag: ErrorBag,
        sessionsRoot: String = piDefaultSessionsRoot()
    ) async -> [SessionEntry] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: sessionsRoot)
        guard fm.fileExists(atPath: rootURL.path) else { return [] }

        // Candidates = (url, mtime) for every *.jsonl under sessionsRoot.
        // If we have a needle, prefer ripgrep to skip files that don't match
        // anywhere in the transcript (matches Codex's pattern).
        var candidates: [(URL, Date)] = []
        var rgFiltered = false
        if !needle.isEmpty,
           let rgPaths = await ripgrepMatchingPaths(needle: needle, root: sessionsRoot, fileGlob: "*.jsonl") {
            rgFiltered = true
            for url in rgPaths {
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                candidates.append((url, mtime))
            }
        } else {
            // Cwd filter fast path: encode the filter to the directory name
            // pi uses, look only in that directory.
            //
            // If the encoded dir is missing OR contains nothing, fall back
            // to walking every other top-level dir under sessionsRoot — we
            // still cwd-filter again post-parse via the JSONL header so
            // alternate-encoding paths (e.g. cwds containing `-` that pi's
            // one-way encoder collapses) are recovered.
            //
            // Critically, the wider walk is GATED on the encoded dir being
            // empty. The previous behavior unconditionally appended every
            // sibling directory's files; with searchMaxFiles=1500 + a global
            // mtime-sort, newer sessions in unrelated cwds could evict
            // older sessions in the requested cwd before we ever parsed
            // them.
            if let cwdFilter, !cwdFilter.isEmpty {
                let dirName = piEncodedSessionDirName(cwd: cwdFilter)
                let dirURL = rootURL.appendingPathComponent(dirName, isDirectory: true)
                if fm.fileExists(atPath: dirURL.path) {
                    candidates.append(contentsOf: enumeratePiJSONL(in: dirURL, fileManager: fm))
                }
                if candidates.isEmpty,
                   let topEnumerator = fm.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                   ) {
                    // URL `!=` is unreliable across constructions (trailing slash,
                    // file:// vs /private/, etc.). Compare by lastPathComponent
                    // since dirName is unique under sessionsRoot.
                    for case let subdir as URL in topEnumerator {
                        guard subdir.lastPathComponent != dirName else { continue }
                        let isDir = (try? subdir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                        guard isDir else { continue }
                        candidates.append(contentsOf: enumeratePiJSONL(in: subdir, fileManager: fm))
                    }
                }
            } else {
                guard let enumerator = fm.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { return [] }
                for case let url as URL in enumerator {
                    guard url.pathExtension == "jsonl" else { continue }
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                    guard values?.isRegularFile == true,
                          let mtime = values?.contentModificationDate else { continue }
                    candidates.append((url, mtime))
                }
            }
        }
        candidates.sort { $0.1 > $1.1 }

        let target = offset + limit
        var matches: [SessionEntry] = []
        var scanned = 0
        // Diagnostic parity with sibling loaders (RovoDev records per-file
        // inspect/read failures via errorBag.add). We collect paths whose
        // session header didn't parse, then surface a single summary line
        // (count + first path) at the end — keeps the index UI signal
        // present without spamming one entry per file. Greptile / coderabbit
        // discussion r3192135211.
        var unparseable: [String] = []
        for (url, mtime) in candidates {
            if Task.isCancelled { break }
            if matches.count >= target { break }
            if scanned >= searchMaxFiles { break }
            scanned += 1

            // If we don't have ripgrep pre-filter, do a head-substring check
            // before the full parse to keep needle searches fast.
            if !needle.isEmpty && !rgFiltered {
                let head = readFileHead(url: url, byteCap: headByteCap)
                guard head.range(of: needle, options: [.caseInsensitive, .literal]) != nil else { continue }
            }

            // Fast cwd reject via header (first line is always the session header).
            if let cwdFilter,
               let firstLineCwd = peekPiSessionHeaderCwd(url: url),
               firstLineCwd != cwdFilter {
                continue
            }

            guard let parsed = extractPiMetadata(url: url) else {
                // Distinguish 'empty file' (pi created the JSONL but hasn't
                // written the header yet — normal during session init) from
                // 'corrupt header'. Only record the latter so the index UI
                // doesn't flag transient empty-on-startup files as errors.
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                if size > 0 {
                    unparseable.append(url.path)
                }
                continue
            }
            if parsed.version != 3 { continue }
            if let cwdFilter, parsed.cwd != cwdFilter { continue }

            let title = piResolveTitle(
                sessionInfoName: parsed.sessionInfoName,
                firstUserMessage: parsed.firstUserMessage
            )
            matches.append(SessionEntry(
                id: "pi:" + url.path,
                agent: .pi,
                sessionId: parsed.sessionId,
                title: title,
                cwd: parsed.cwd,
                gitBranch: nil,
                pullRequest: nil,
                modified: mtime,
                fileURL: url,
                specifics: .pi(provider: parsed.provider, model: parsed.model)
            ))
        }
        if let firstUnparseable = unparseable.first {
            // Match RovoDev's "<Agent>: cannot <verb> <path> (<reason>)" shape.
            errorBag.add(
                "Pi: skipped \(unparseable.count) session file(s) with unreadable header (e.g. \(firstUnparseable))"
            )
        }
        return Array(matches.dropFirst(offset).prefix(limit))
    }

    #if DEBUG
    nonisolated static func loadPiEntriesForTesting(
        sessionsRoot: String,
        needle: String = "",
        cwdFilter: String? = nil,
        offset: Int = 0,
        limit: Int = 100
    ) async -> SearchOutcome {
        let bag = ErrorBag()
        let entries = await loadPiEntries(
            needle: needle,
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit,
            errorBag: bag,
            sessionsRoot: sessionsRoot
        )
        return SearchOutcome(entries: entries, errors: bag.snapshot())
    }
    #endif

    // MARK: Helpers (internal so tests can poke at them)

    /// `~/.pi/agent/sessions/`
    nonisolated static func piDefaultSessionsRoot() -> String {
        let home = ProcessInfo.processInfo.environment["HOME"].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".pi/agent/sessions")
    }

    /// Mirror of pi's session-manager.js encoding:
    ///   `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`
    /// Used for the cwdFilter fast path. Decoding is intentionally not
    /// implemented (encoding is lossy when a path contains `-`).
    nonisolated static func piEncodedSessionDirName(cwd: String) -> String {
        var stripped = cwd
        if stripped.hasPrefix("/") || stripped.hasPrefix("\\") {
            stripped.removeFirst()
        }
        let replaced = stripped
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "--\(replaced)--"
    }

    nonisolated private static func enumeratePiJSONL(
        in directory: URL,
        fileManager: FileManager
    ) -> [(URL, Date)] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  let mtime = values?.contentModificationDate else { continue }
            result.append((url, mtime))
        }
        return result
    }

    /// Reads only the first line of `url` and returns the `cwd` field if it's
    /// a valid pi session header. Returns nil otherwise.
    nonisolated static func peekPiSessionHeaderCwd(url: URL) -> String? {
        let head = readFileHead(url: url, byteCap: headByteCap)
        guard let nl = head.firstIndex(of: "\n") else { return nil }
        let firstLine = head[..<nl]
        guard let data = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "session",
              let cwd = obj["cwd"] as? String,
              !cwd.isEmpty else {
            return nil
        }
        return cwd
    }

    /// Parsed metadata from a single pi session JSONL file. All fields are
    /// optional / defaulted because pi files can be partially written and we
    /// want lenient parsing for the index.
    private struct PiParsed: Equatable {
        var version: Int = 0
        var sessionId: String = ""
        var cwd: String?
        var sessionInfoName: String?
        var firstUserMessage: String?
        var provider: String?
        var model: String?
    }

    /// Stream the JSONL file and pull out:
    ///   - header (`type: "session"`): version, id, cwd
    ///   - latest `session_info.name` (overrides title)
    ///   - first user message (fallback title)
    ///   - latest `model_change` provider + modelId
    ///
    /// Returns nil if the file has no parseable session header (likely empty
    /// file mid-write or corrupted).
    nonisolated private static func extractPiMetadata(url: URL) -> PiParsed? {
        var out = PiParsed()
        var sawHeader = false
        let maxBytes = 4 * 1024 * 1024
        forEachJSONLine(url: url, maxBytes: maxBytes) { obj in
            let type = obj["type"] as? String
            switch type {
            case "session":
                sawHeader = true
                if let v = obj["version"] as? Int { out.version = v }
                if let id = obj["id"] as? String, !id.isEmpty { out.sessionId = id }
                if let cwd = obj["cwd"] as? String, !cwd.isEmpty { out.cwd = cwd }
            case "session_info":
                if let name = obj["name"] as? String, !name.isEmpty {
                    // Take the LATEST session_info.name (later overrides earlier).
                    out.sessionInfoName = name
                }
            case "model_change":
                if let provider = obj["provider"] as? String, !provider.isEmpty {
                    out.provider = provider
                }
                if let model = obj["modelId"] as? String, !model.isEmpty {
                    out.model = model
                }
            case "message":
                if out.firstUserMessage == nil {
                    if let message = obj["message"] as? [String: Any],
                       (message["role"] as? String) == "user",
                       let text = piExtractUserText(message["content"]),
                       !text.isEmpty {
                        out.firstUserMessage = text
                    }
                }
            default:
                break
            }
            // Don't early-return; we want the LATEST session_info.name and the
            // LATEST model_change. Cap the read at maxBytes to avoid scanning
            // multi-MB transcripts forever; that's enough for any session that
            // would render on the sidebar.
            return false
        }
        guard sawHeader else { return nil }
        return out
    }

    /// pi user message content can be either a plain string or an array of
    /// `{type:"text",text:"..."}` parts. Return the first non-empty text part.
    nonisolated private static func piExtractUserText(_ raw: Any?) -> String? {
        if let str = raw as? String {
            return str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let array = raw as? [[String: Any]] {
            for part in array {
                guard (part["type"] as? String) == "text",
                      let text = part["text"] as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Title rules (matches the Sessions/Vault expectation):
    ///   - if user set a name via `/name <name>`, use it verbatim
    ///   - else use the first user message, single-lined and truncated to 80
    ///   - else "(untitled)"
    nonisolated private static func piResolveTitle(
        sessionInfoName: String?,
        firstUserMessage: String?
    ) -> String {
        if let name = sessionInfoName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let message = firstUserMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            let collapsed = message
                .split(whereSeparator: { $0.isNewline })
                .joined(separator: " ")
            let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
            if trimmed.count <= 80 { return trimmed }
            let prefix = trimmed.prefix(80)
            return String(prefix) + "\u{2026}"  // U+2026 HORIZONTAL ELLIPSIS
        }
        return String(localized: "sessionIndex.pi.untitled", defaultValue: "(untitled)")
    }
}
