import Foundation

/// Metadata parsed out of a Claude Code `.jsonl` transcript by scanning its
/// head (first records) and tail (last records). Fields default to empty/nil so
/// a transcript missing a value simply leaves that field unset.
struct ClaudeParsed {
    var title: String = ""
    var cwd: String?
    var branch: String?
    var pr: PullRequestLink?
    var model: String?
    var permissionMode: String?

    init() {}

    /// Parse Claude session metadata from a transcript `head`/`tail` window.
    /// `projectDir` is the encoded project directory name (used to recover the
    /// cwd when the JSONL `cwd` field is absent).
    init(head: String, tail: String, projectDir: String) {
        self.init()
        self.cwd = ClaudeParsed.decodeProjectDir(projectDir)

        for line in head.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let isMeta = (obj["isMeta"] as? Bool) ?? false
            if let cwdField = obj["cwd"] as? String, !cwdField.isEmpty {
                self.cwd = cwdField
            }
            if let branchField = obj["gitBranch"] as? String, !branchField.isEmpty {
                self.branch = branchField
            }
            if let mode = obj["permissionMode"] as? String, !mode.isEmpty {
                self.permissionMode = mode
            }
            if (obj["type"] as? String) == "assistant",
               let message = obj["message"] as? [String: Any],
               let model = message["model"] as? String, !model.isEmpty {
                self.model = model
            }
            if self.title.isEmpty,
               (obj["type"] as? String) == "user",
               let message = obj["message"] as? [String: Any],
               (message["role"] as? String) == "user" {
                if let content = message["content"] as? String,
                   let title = SessionEntry.claudeDisplayTitle(from: content, isMeta: isMeta) {
                    self.title = title
                } else if let parts = message["content"] as? [[String: Any]] {
                    for part in parts {
                        if (part["type"] as? String) == "text",
                           let text = part["text"] as? String,
                           let title = SessionEntry.claudeDisplayTitle(from: text, isMeta: isMeta) {
                            self.title = title
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
                self.pr = PullRequestLink(
                    number: number,
                    url: url,
                    repository: obj["prRepository"] as? String
                )
            }
            if let branchField = obj["gitBranch"] as? String, !branchField.isEmpty {
                self.branch = branchField
            }
            if let mode = obj["permissionMode"] as? String, !mode.isEmpty {
                self.permissionMode = mode
            }
            if (obj["type"] as? String) == "assistant",
               let message = obj["message"] as? [String: Any],
               let model = message["model"] as? String, !model.isEmpty {
                self.model = model
            }
        }
        // Strip the [1m] suffix some Claude internal model IDs carry (claude-opus-4-7[1m]).
        if let m = self.model, let bracket = m.firstIndex(of: "[") {
            self.model = String(m[..<bracket])
        }
    }

    /// Decode a Claude project directory name back into the original cwd path.
    ///
    /// Claude encodes cwd by replacing "/" with "-" and prefixing "-"
    /// e.g. "-Users-lawrence-fun-cmuxterm-hq" -> "/Users/lawrence/fun/cmuxterm-hq".
    /// The encoding is lossy: a real path segment containing "-"
    /// (e.g. "my-cool-project") collapses to multiple segments
    /// ("/my/cool/project") on decode, which is wrong. Only return the
    /// candidate if it actually exists on disk; otherwise let the caller
    /// fall back to the JSONL `cwd` field.
    private static func decodeProjectDir(_ raw: String) -> String? {
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
}
