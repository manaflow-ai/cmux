import Foundation

/// Pluggable source for the "what did the agent touch this turn?" transcript
/// channel used by `ClaudeTranscriptTailer` (and `TurnCheckpointRegistry`) to
/// detect which git repos a workspace's agent is operating on. Today only Claude
/// Code is implemented; the protocol exists so future agents (Codex, Aider,
/// OpenCode, etc.) can plug in by:
///   1. Pointing `transcriptDirectory(forAnchorPwd:)` at their on-disk
///      transcript dir (the tailer picks the most recent .jsonl in it).
///   2. Implementing `extractPaths(fromLine:anchorPwd:)` to pull absolute file
///      paths out of one transcript JSONL line.
///
/// Selection happens once per workspace at attach time via the factory, which
/// reads `perTurnDiff.agentTranscriptSource` from `~/.config/cmux/settings.json`.
///
/// Implementations must be `Sendable` and safe to call off the main actor — the
/// tailer invokes them on its own background DispatchQueue.
protocol AgentTranscriptSource: Sendable {
    /// Where to look for the active transcript file given the workspace's anchor
    /// pwd (typically the focused-pane pwd, falling back to workspace cwd).
    /// Returns the directory; the tailer picks the most recent .jsonl in it.
    /// May return nil if the agent's transcript layout depends on something
    /// other than a per-cwd directory and isn't known yet for this anchor.
    func transcriptDirectory(forAnchorPwd anchorPwd: String) -> URL?

    /// Extract any absolute file paths or `cd <path>` targets from one transcript
    /// JSONL line. Implementations should return paths in absolute form (the
    /// tailer's emit step handles tilde expansion + relative-to-anchor join,
    /// but absolute is preferred here).
    func extractPaths(fromLine line: Data, anchorPwd: String) -> [String]
}

/// Default impl: tails Claude Code's `~/.claude/projects/<sanitized cwd>/*.jsonl`.
/// Encapsulates the existing logic that used to live inline in
/// `ClaudeTranscriptTailer`: project-dir resolution by sanitized cwd, and
/// JSONL parse for `tool_use` entries (Edit/Write/MultiEdit/Read/NotebookEdit
/// `file_path` plus Bash `command` `cd <path>` and absolute-path targets).
struct ClaudeCodeTranscriptSource: AgentTranscriptSource {
    func transcriptDirectory(forAnchorPwd anchorPwd: String) -> URL? {
        let claudeRoot = ("~/.claude/projects" as NSString).expandingTildeInPath
        let encoded = anchorPwd.replacingOccurrences(of: "/", with: "-")
        return URL(fileURLWithPath: claudeRoot, isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
    }

    func extractPaths(fromLine line: Data, anchorPwd: String) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: line),
              let dict = obj as? [String: Any] else { return [] }

        var out: [String] = []

        // Tool-use entries live nested inside `message.content[]` for assistant
        // messages. Walk both the legacy top-level shape and the nested shape.
        if let type = dict["type"] as? String, type == "tool_use" {
            extractToolUse(dict, anchor: anchorPwd, into: &out)
        }
        if let message = dict["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for entry in content {
                if (entry["type"] as? String) == "tool_use" {
                    extractToolUse(entry, anchor: anchorPwd, into: &out)
                }
            }
        }
        return out
    }

    /// Pull `file_path` (Edit/Write/MultiEdit/Read/NotebookEdit) and `command`-cd
    /// targets (Bash) out of a tool_use object, resolve to absolute paths, and
    /// append into `out`.
    private func extractToolUse(
        _ tu: [String: Any],
        anchor: String,
        into out: inout [String]
    ) {
        let name = (tu["name"] as? String) ?? ""
        guard let input = tu["input"] as? [String: Any] else { return }

        switch name {
        case "Write", "Edit", "MultiEdit", "Read", "NotebookEdit":
            if let path = input["file_path"] as? String,
               let abs = Self.absolutize(path, anchor: anchor) {
                out.append(abs)
            }

        case "Bash":
            if let cmd = input["command"] as? String {
                for cdPath in Self.extractCdTargets(from: cmd) {
                    if let abs = Self.absolutize(cdPath, anchor: anchor) {
                        out.append(abs)
                    }
                }
                for absRaw in Self.extractAbsolutePaths(from: cmd) {
                    if let abs = Self.absolutize(absRaw, anchor: anchor) {
                        out.append(abs)
                    }
                }
            }

        default:
            break
        }
    }

    /// Find `cd <path>` arguments. Tolerates `&&`, `;`, and quoted paths.
    private static func extractCdTargets(from cmd: String) -> [String] {
        let separators = CharacterSet(charactersIn: ";&|")
        var results: [String] = []
        for piece in cmd.unicodeScalars
            .split(whereSeparator: { separators.contains($0) })
            .map({ String(String.UnicodeScalarView($0)) })
        {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("cd ") || trimmed == "cd" else { continue }
            let rest = trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.isEmpty { continue }
            let token = rest.split(separator: " ", maxSplits: 1).first.map(String.init) ?? rest
            var unquoted = token
            for quote in ["\"", "'"] {
                if unquoted.hasPrefix(quote) && unquoted.hasSuffix(quote) && unquoted.count >= 2 {
                    unquoted = String(unquoted.dropFirst().dropLast())
                }
            }
            results.append(unquoted)
        }
        return results
    }

    /// Best-effort scan for absolute paths in a command string.
    private static func extractAbsolutePaths(from cmd: String) -> [String] {
        var out: [String] = []
        var current: [Character] = []
        for ch in cmd {
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\"" || ch == "'" {
                if !current.isEmpty {
                    let s = String(current)
                    if s.hasPrefix("/") { out.append(s) }
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            let s = String(current)
            if s.hasPrefix("/") { out.append(s) }
        }
        return out
    }

    /// Resolve `rawPath` to an absolute path. Relative paths are joined onto
    /// `anchor`; tilde paths are expanded.
    private static func absolutize(_ rawPath: String, anchor: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return expanded
        }
        return (anchor as NSString).appendingPathComponent(expanded)
    }
}

/// Factory that maps a settings string to an `AgentTranscriptSource`.
/// Unknown values fall back to Claude Code with a debug log.
enum AgentTranscriptSourceFactory {
    /// Setting key in `~/.config/cmux/settings.json`.
    static let settingKey = "perTurnDiff.agentTranscriptSource"
    static let defaultValue = "claude-code"

    static func make(forSettingValue value: String) -> AgentTranscriptSource {
        switch value.lowercased() {
        case "claude-code", "":
            return ClaudeCodeTranscriptSource()
        default:
            #if DEBUG
            cmuxDebugLog(
                "turn-diff: unknown agent transcript source '\(value)', defaulting to claude-code"
            )
            #endif
            return ClaudeCodeTranscriptSource()
        }
    }

    /// Read `perTurnDiff.agentTranscriptSource` from `~/.config/cmux/settings.json`
    /// (silent fallback to default on any error / missing key) and build the
    /// matching source. Called once per workspace at attach time.
    @MainActor
    static func makeFromCurrentSettings() -> AgentTranscriptSource {
        let value = readAgentTranscriptSourceSetting() ?? defaultValue
        return make(forSettingValue: value)
    }

    /// Best-effort read of the `perTurnDiff.agentTranscriptSource` string from
    /// the user's settings.json. Returns nil if the file is missing, unreadable,
    /// or the key isn't set. Mirrors the path resolution used by
    /// `CmuxSettingsFileStore` (primary `~/.config/cmux/settings.json`, falling
    /// back to the Application Support copy).
    private static func readAgentTranscriptSourceSetting() -> String? {
        let candidates = settingsFileCandidates()
        for path in candidates {
            guard let data = FileManager.default.contents(atPath: path),
                  !data.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let root = obj as? [String: Any] else {
                continue
            }
            if let section = root["perTurnDiff"] as? [String: Any],
               let value = section["agentTranscriptSource"] as? String,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func settingsFileCandidates() -> [String] {
        var paths: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths.append((home as NSString).appendingPathComponent(".config/cmux/settings.json"))
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            paths.append(
                appSupport
                    .appendingPathComponent("com.cmuxterm.app", isDirectory: true)
                    .appendingPathComponent("settings.json", isDirectory: false)
                    .path
            )
        }
        return paths
    }
}
