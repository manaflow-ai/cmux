import CmuxNextCompat
package import Foundation

/// Finds the pull request an agent session opened. Claude Code writes a
/// `{"type":"pr-link","prUrl":…}` line into the session's transcript
/// (`<projects>/<folder>/<session id>.jsonl`) when it creates or links a pull
/// request; the newest such line wins. Other agents record none yet.
package nonisolated struct VaultPullRequests: Sendable {
    /// The Claude Code `projects` folders searched, in order.
    package let claudeProjects: [URL]
    /// How much of a transcript's end is read (pr-link lines sit near the end).
    package let tailBytes: Int

    /// - Parameter claudeProjects: Defaults to `$CLAUDE_CONFIG_DIR/projects` and `~/.claude/projects`.
    package init(claudeProjects: [URL]? = nil, tailBytes: Int = 1 << 20,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.claudeProjects = claudeProjects ?? Self.defaultProjects(environment: environment)
        self.tailBytes = tailBytes
    }

    package static func defaultProjects(environment: [String: String]) -> [URL] {
        var roots: [URL] = []
        if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
            roots.append(URL(fileURLWithPath: (config as NSString).expandingTildeInPath).appendingPathComponent("projects"))
        }
        roots.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"))
        return roots
    }

    /// The session's pull request URL, read off the main actor; nil when none is recorded.
    package func url(provider: String, sessionID: String) async -> URL? {
        let finder = self
        return await Task.detached(priority: .userInitiated) { finder.find(provider: provider, sessionID: sessionID) }.value
    }

    package func find(provider: String, sessionID: String) -> URL? {
        guard ["claude", "claude-code", "claude_code"].contains(provider.lowercased()),
              !sessionID.isEmpty, !sessionID.contains("/"), !sessionID.hasPrefix(".") else { return nil }
        for transcript in transcripts(sessionID: sessionID) {
            if let url = lastPullRequest(in: transcript) { return url }
        }
        return nil
    }

    private func transcripts(sessionID: String) -> [URL] {
        let name = sessionID + ".jsonl"
        return claudeProjects.flatMap { root -> [URL] in
            let folders = (try? FileManager.checked.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return folders.map { $0.appendingPathComponent(name) }.filter { FileManager.checked.fileExists(atPath: $0.path) }
        }
    }

    private func lastPullRequest(in transcript: URL) -> URL? {
        guard let handle = try? FileHandle.blockingForReading(from: transcript) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.blockingSeekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        // concurrency-allow: one capped tail read; the app runs it in a detached task (`url`), off the main actor
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.contains("pr-link") {
            guard let object = try? JSONSerialization.blockingJSONObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "pr-link", let link = object["prUrl"] as? String,
                  let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            return url
        }
        return nil
    }
}
