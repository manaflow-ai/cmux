import Foundation

/// Resolves a Codex session id from disk for a live, hook-less codex process,
/// given only its working directory and environment. Codex writes one rollout
/// file per session under `$CODEX_HOME/sessions` (default `~/.codex/sessions`),
/// date-sharded as `YYYY/MM/DD/rollout-<ts>-<id>.jsonl`. The first JSONL line is
/// a `session_meta` record carrying `payload.id` and `payload.cwd` (both appear
/// before the very large `base_instructions`, so a small head read suffices).
///
/// Used by live-process detection (Sources/VaultAgentProcessScanner.swift) so a
/// CMUX-scoped codex process that cmux never recorded a hook for can still be
/// resumed/forked. Resolution is the newest rollout whose `cwd` matches; callers
/// gate this behind a single-process-per-cwd guard so an ambiguous cwd never
/// forks the wrong conversation.
public struct CodexSessionResolver {
    private struct SessionMeta {
        let sessionId: String
        let cwd: String
    }

    /// id + cwd sit in the first few hundred bytes of the first line, ahead of
    /// the multi-KB `base_instructions`; cap the head read so a huge rollout is
    /// cheap to peek (we only need the early fields).
    private let headByteCap = 16 * 1024

    /// Upper bound on rollout files we open+read per resolve. The live session is
    /// actively written, so it sits at/near the top of the mtime-sorted list and
    /// is found in a handful of peeks; this only bounds the no-match worst case
    /// so a heavy user's full history is never fully read on a single scan.
    private let maxPeeks = 128

    private let fileManager: FileManager

    /// Creates a resolver.
    ///
    /// - Parameter fileManager: Injected so tests can point resolution at a
    ///   temporary `CODEX_HOME`; defaults to `.default`.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Returns the id of the newest Codex rollout whose recorded `cwd` matches
    /// `cwd`, or `nil` when `cwd` is empty/unresolvable or no rollout matches.
    ///
    /// - Parameters:
    ///   - cwd: The live process working directory; symlink-normalized before
    ///     comparison so an aliased path still matches the rollout's `cwd`.
    ///   - env: The process environment, read for a `CODEX_HOME` override.
    public func inferredCodexSessionId(cwd: String?, env: [String: String]) -> String? {
        guard let normalizedCwd = RovoDevIndex.normalizedPath(cwd), !normalizedCwd.isEmpty else {
            return nil
        }
        let rootURL = URL(fileURLWithPath: codexSessionsRoot(env: env), isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        // Codex shards rollouts by date and does NOT encode the cwd in the path,
        // so the matching session can only be found by reading `session_meta`.
        // Collect candidate files with just their mtime (a stat, no open), then
        // open+read newest-first and stop at the first cwd match — avoids opening
        // every rollout in a long history on each scan.
        var files: [(url: URL, modified: Date)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl",
                  fileURL.lastPathComponent.hasPrefix("rollout-") else {
                continue
            }
            let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((fileURL, modified))
        }
        files.sort {
            // Newest mtime first; break ties on filename (which carries the
            // start timestamp + id) so resolution is deterministic.
            $0.modified != $1.modified
                ? $0.modified > $1.modified
                : $0.url.lastPathComponent > $1.url.lastPathComponent
        }

        var peeks = 0
        for file in files {
            guard peeks < maxPeeks else { break }
            peeks += 1
            guard let meta = peekSessionMeta(url: file.url),
                  let metaCwd = RovoDevIndex.normalizedPath(meta.cwd),
                  metaCwd == normalizedCwd else {
                continue
            }
            return meta.sessionId
        }
        return nil
    }

    /// The directory Codex writes rollouts under: `$CODEX_HOME/sessions` when
    /// `CODEX_HOME` is set in `env`, otherwise `~/.codex/sessions`.
    public func codexSessionsRoot(env: [String: String]) -> String {
        if let codexHome = normalizedValue(env["CODEX_HOME"]) {
            return (expandedPath(codexHome, env: env) as NSString).appendingPathComponent("sessions")
        }
        let home = normalizedValue(env["HOME"]) ?? NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".codex/sessions")
    }

    // MARK: - Session meta peek

    private func peekSessionMeta(url: URL) -> SessionMeta? {
        guard let head = readHead(url: url, byteCap: headByteCap) else { return nil }
        // Only the first JSONL line is the `session_meta`. On small files the
        // full line is present (JSON-parse it); on real files `base_instructions`
        // overflows the head cap, so fall back to regex over the early bytes,
        // where `id` and `cwd` always live.
        let firstLine = head.firstIndex(of: "\n").map { String(head[..<$0]) } ?? head
        if let data = firstLine.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (object["type"] as? String) == "session_meta",
           let payload = object["payload"] as? [String: Any],
           let id = nonEmpty(payload["id"] as? String),
           let cwd = nonEmpty(payload["cwd"] as? String) {
            return SessionMeta(sessionId: id, cwd: cwd)
        }
        guard let id = firstCapture(in: firstLine, pattern: #""id"\s*:\s*"([^"\\]+)""#),
              let cwd = firstCapture(in: firstLine, pattern: #""cwd"\s*:\s*"([^"\\]+)""#) else {
            return nil
        }
        return SessionMeta(sessionId: id, cwd: cwd)
    }

    private func readHead(url: URL, byteCap: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: byteCap)) ?? Data()
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return nonEmpty(String(text[captured]))
    }

    // MARK: - Path helpers

    private func normalizedValue(_ raw: String?) -> String? {
        nonEmpty(raw?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func expandedPath(_ path: String, env: [String: String]) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "~" || trimmed.hasPrefix("~/") else {
            return (trimmed as NSString).expandingTildeInPath
        }
        let home = normalizedValue(env["HOME"]) ?? NSHomeDirectory()
        guard trimmed != "~" else { return home }
        return (home as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
    }
}
