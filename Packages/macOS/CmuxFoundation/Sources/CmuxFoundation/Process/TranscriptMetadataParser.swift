public import Foundation

/// Pure transcript-parsing substrate for agent session indexing.
///
/// Parses the JSON-line transcripts that Claude (`*.jsonl` under
/// `~/.claude/projects`), Codex (`~/.codex/sessions/*.jsonl` rollouts), and
/// OpenCode (`message` rows) write, extracting the metadata the session index
/// surfaces (title, cwd, git branch, model, permission/approval/sandbox modes,
/// pull-request link).
///
/// This is an instance value type, not a static-utility namespace. It holds a
/// `RipgrepFileScanner` (for the bounded file-head/stream reads Codex needs) and
/// the byte caps that bound those reads, all injected at construction so the
/// parser stays decoupled from app-side file-scan wiring and is testable with a
/// fake scanner. None of the parsing reaches app types: the Claude parser takes a
/// `displayTitle` closure (the app passes its `SessionEntry.claudeDisplayTitle`)
/// and reports pull-request links as the parser-owned ``TranscriptPullRequestLink``
/// so the caller maps it onto its own model. App-coupled discovery
/// (config-root resolution, project-dir encoding, candidate enumeration) stays
/// app-side and feeds this parser the already-read `head`/`tail` strings or file
/// URLs.
public struct TranscriptMetadataParser: Sendable {
    /// The scanner used for Codex head-peek and full-rollout streaming reads.
    public let scanner: RipgrepFileScanner
    /// Byte cap for reading a transcript head (covers Codex's large first line).
    public let headByteCap: Int

    /// Create a parser.
    /// - Parameters:
    ///   - scanner: Bounded file-read substrate for the Codex parsers.
    ///   - headByteCap: Cap for the Codex `session_meta` head peek. Defaults to 64 KB.
    public init(scanner: RipgrepFileScanner, headByteCap: Int = 64 * 1024) {
        self.scanner = scanner
        self.headByteCap = headByteCap
    }

    // MARK: - Claude

    /// A pull-request link recovered from a Claude transcript's `pr-link` event.
    ///
    /// Parser-owned so the parser never reaches an app model. The caller maps
    /// this onto its own pull-request type.
    public struct TranscriptPullRequestLink: Hashable, Sendable {
        public let number: Int
        public let url: String
        public let repository: String?

        public init(number: Int, url: String, repository: String?) {
            self.number = number
            self.url = url
            self.repository = repository
        }
    }

    /// Metadata extracted from a Claude `*.jsonl` transcript.
    public struct ClaudeTranscriptMetadata: Sendable {
        public var title: String = ""
        public var cwd: String?
        public var branch: String?
        public var pr: TranscriptPullRequestLink?
        public var model: String?
        public var permissionMode: String?

        public init() {}
    }

    /// Parse a Claude transcript's head + tail slices into session metadata.
    ///
    /// - Parameters:
    ///   - head: UTF-8 head of the transcript (first user message, cwd, branch, mode).
    ///   - tail: UTF-8 tail of the transcript (late `pr-link`, branch, mode events).
    ///   - projectDir: The Claude project directory name (encoded cwd) used as a
    ///     fallback cwd when no JSONL `cwd` field is present.
    ///   - displayTitle: Derives a display title from a user-message string, or
    ///     `nil` when the content should not become a title. The app passes its
    ///     `SessionEntry.claudeDisplayTitle(from:isMeta:)`; kept app-side because
    ///     it is an app-model concern.
    /// - Returns: The parsed metadata.
    public func extractClaudeMetadata(
        head: String,
        tail: String,
        projectDir: String,
        displayTitle: (_ content: String, _ isMeta: Bool) -> String?
    ) -> ClaudeTranscriptMetadata {
        var out = ClaudeTranscriptMetadata()
        out.cwd = decodeClaudeProjectDir(projectDir)

        for line in head.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let isMeta = (obj["isMeta"] as? Bool) ?? false
            if let cwdField = obj["cwd"] as? String, !cwdField.isEmpty {
                out.cwd = cwdField
            }
            if let branchField = obj["gitBranch"] as? String, !branchField.isEmpty {
                out.branch = branchField
            }
            if let mode = obj["permissionMode"] as? String, !mode.isEmpty {
                out.permissionMode = mode
            }
            if (obj["type"] as? String) == "assistant",
               let message = obj["message"] as? [String: Any],
               let model = message["model"] as? String, !model.isEmpty {
                out.model = model
            }
            if out.title.isEmpty,
               (obj["type"] as? String) == "user",
               let message = obj["message"] as? [String: Any],
               (message["role"] as? String) == "user" {
                if let content = message["content"] as? String,
                   let title = displayTitle(content, isMeta) {
                    out.title = title
                } else if let parts = message["content"] as? [[String: Any]] {
                    for part in parts {
                        if (part["type"] as? String) == "text",
                           let text = part["text"] as? String,
                           let title = displayTitle(text, isMeta) {
                            out.title = title
                            break
                        }
                    }
                }
            }
        }

        for line in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            if type == "pr-link", let number = obj["prNumber"] as? Int,
               let url = obj["prUrl"] as? String {
                out.pr = TranscriptPullRequestLink(
                    number: number,
                    url: url,
                    repository: obj["prRepository"] as? String
                )
            }
            if let branchField = obj["gitBranch"] as? String, !branchField.isEmpty {
                out.branch = branchField
            }
            if let mode = obj["permissionMode"] as? String, !mode.isEmpty {
                out.permissionMode = mode
            }
            if (obj["type"] as? String) == "assistant",
               let message = obj["message"] as? [String: Any],
               let model = message["model"] as? String, !model.isEmpty {
                out.model = model
            }
        }
        // Strip the [1m] suffix some Claude internal model IDs carry (claude-opus-4-7[1m]).
        if let m = out.model, let bracket = m.firstIndex(of: "[") {
            out.model = String(m[..<bracket])
        }
        return out
    }

    /// Decode a Claude project-directory name back to an absolute cwd, or `nil`.
    ///
    /// Claude encodes cwd by replacing "/" with "-" and prefixing "-"
    /// e.g. "-Users-lawrence-fun-cmuxterm-hq" -> "/Users/lawrence/fun/cmuxterm-hq".
    /// The encoding is lossy: a real path segment containing "-"
    /// (e.g. "my-cool-project") collapses to multiple segments
    /// ("/my/cool/project") on decode, which is wrong. Only returns the
    /// candidate if it actually exists on disk; otherwise the caller falls back
    /// to the JSONL `cwd` field.
    public func decodeClaudeProjectDir(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let stripped = raw.hasPrefix("-") ? String(raw.dropFirst()) : raw
        let candidate = "/" + stripped.replacingOccurrences(of: "-", with: "/")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        return candidate
    }

    /// The Claude project-directory name for a transcript `url` under `projectsRoot`.
    ///
    /// Returns the first path segment of `url` below `projectsRoot`, falling back
    /// to the URL's parent directory name when `url` is not under the root.
    public func claudeProjectDirName(for url: URL, projectsRoot: String) -> String {
        let root = projectsRoot.hasSuffix("/") ? projectsRoot : projectsRoot + "/"
        guard url.path.hasPrefix(root) else {
            return url.deletingLastPathComponent().lastPathComponent
        }
        let relative = String(url.path.dropFirst(root.count))
        return relative.split(separator: "/", maxSplits: 1).first.map(String.init)
            ?? url.deletingLastPathComponent().lastPathComponent
    }

    // MARK: - Codex

    /// Metadata extracted from a Codex `*.jsonl` rollout.
    public struct CodexTranscriptMetadata: Sendable {
        public var sessionId: String = ""
        /// First user message — used only if Codex never assigns a thread_name.
        public var firstUserMessage: String = ""
        /// Codex-generated session title (`event_msg.thread_name_updated`). Wins over firstUserMessage.
        public var threadName: String = ""
        public var cwd: String?
        public var branch: String?
        public var model: String?
        public var approvalPolicy: String?
        public var sandboxMode: String?
        public var effort: String?

        public init() {}

        public var title: String {
            threadName.isEmpty ? firstUserMessage : threadName
        }
    }

    /// Cheap cwd peek for Codex rollouts. `session_meta` is always the first line
    /// of the file, but the line itself can be 30+ KB (it embeds the full system
    /// prompt). Reads up to `headByteCap` to cover that, parses the JSON, returns cwd.
    public func peekCodexSessionMetaCwd(url: URL) -> String? {
        let head = scanner.readFileHead(url: url, byteCap: headByteCap)
        guard let nl = head.firstIndex(of: "\n") else { return nil }
        let firstLine = head[..<nl]
        guard let data = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String,
              !cwd.isEmpty else {
            return nil
        }
        return cwd
    }

    /// Stream lines from `url` until we have everything we need. The first user_message
    /// can sit ~100 KB into a Codex rollout (after huge base_instructions + AGENTS.md),
    /// so a fixed head buffer is unreliable.
    public func extractCodexMetadata(url: URL) -> CodexTranscriptMetadata {
        var out = CodexTranscriptMetadata()
        let maxBytes = 4 * 1024 * 1024
        scanner.forEachJSONLine(url: url, maxBytes: maxBytes) { obj in
            let type = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any]
            if type == "session_meta", let p = payload {
                if let c = p["cwd"] as? String, !c.isEmpty { out.cwd = c }
                if let id = p["id"] as? String, !id.isEmpty { out.sessionId = id }
                if let git = p["git"] as? [String: Any],
                   let branch = git["branch"] as? String, !branch.isEmpty {
                    out.branch = branch
                }
            }
            if type == "turn_context", let p = payload {
                if let m = p["model"] as? String, !m.isEmpty { out.model = m }
                if let a = p["approval_policy"] as? String, !a.isEmpty { out.approvalPolicy = a }
                if let sandbox = p["sandbox_policy"] as? [String: Any],
                   let s = sandbox["type"] as? String, !s.isEmpty {
                    out.sandboxMode = s
                }
                if let e = p["effort"] as? String, !e.isEmpty { out.effort = e }
            }
            if type == "event_msg", let p = payload,
               (p["type"] as? String) == "thread_name_updated",
               let name = p["thread_name"] as? String, !name.isEmpty {
                out.threadName = name
            }
            if out.firstUserMessage.isEmpty, type == "event_msg", let p = payload,
               (p["type"] as? String) == "user_message",
               let msg = p["message"] as? String,
               let real = scanner.realCodexUserMessage(msg) {
                out.firstUserMessage = real
            }
            if out.firstUserMessage.isEmpty, type == "response_item", let p = payload,
               (p["type"] as? String) == "message",
               (p["role"] as? String) == "user",
               let content = p["content"] as? [[String: Any]] {
                for part in content {
                    guard (part["type"] as? String) == "input_text",
                          let text = part["text"] as? String,
                          let real = scanner.realCodexUserMessage(text) else { continue }
                    out.firstUserMessage = real
                    break
                }
            }
            // Stop early once we have a real thread name + the launch metadata. If no
            // thread name appears we keep streaming until we at least have a user
            // message — Codex emits thread_name_updated late in newer versions but it's
            // still typically within the first few KB of events.
            return !out.threadName.isEmpty
                && out.cwd != nil
                && out.branch != nil
                && !out.sessionId.isEmpty
                && out.model != nil
        }
        return out
    }

    // MARK: - OpenCode

    /// Parse an OpenCode assistant `message` row into `(providerModel, agentName)`.
    ///
    /// `providerModel` joins provider + model as "provider/model" when both are
    /// present, or the bare model when only it is present. `agentName` is the
    /// `agent` field, or `nil` when empty.
    public func parseOpenCodeAssistant(_ raw: String?) -> (String?, String?) {
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let modelID = obj["modelID"] as? String
        let providerID = obj["providerID"] as? String
        let agentName = obj["agent"] as? String
        let providerModel: String? = {
            switch (providerID, modelID) {
            case let (p?, m?) where !p.isEmpty && !m.isEmpty: return "\(p)/\(m)"
            case let (_, m?) where !m.isEmpty: return m
            default: return nil
            }
        }()
        return (providerModel, agentName?.isEmpty == false ? agentName : nil)
    }
}
