import Foundation

/// Clipboard-safe text assembled by the focused chat copy actions. File rows are paths only:
/// config and transcript contents can contain credentials, so copying them is an explicit follow-up
/// rather than a side effect of copying session metadata.
enum AgentChatCopyText {
    struct File: Sendable, Hashable {
        let label: String
        let path: String

        init(label: String, path: String) {
            self.label = label
            self.path = path
        }
    }

    static func details(name: String?, identifier: String, harnessSessionID: String?, cwd: String?, host: String?, files: [File]) -> String {
        var lines: [String] = []
        if let name, !name.isEmpty { lines.append("Agent name: \(name)") }
        lines.append("Agent identifier: \(identifier)")
        if let harnessSessionID, !harnessSessionID.isEmpty { lines.append("Harness session ID: \(harnessSessionID)") }
        if let cwd, !cwd.isEmpty { lines.append("CWD: \(cwd)") }
        if let host, !host.isEmpty { lines.append("Host: \(host)") }
        lines.append(contentsOf: files.filter { !$0.path.isEmpty }.map { "\($0.label): \($0.path)" })
        return lines.joined(separator: "\n")
    }
}
