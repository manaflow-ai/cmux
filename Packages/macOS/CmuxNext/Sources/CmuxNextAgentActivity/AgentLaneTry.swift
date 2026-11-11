public import Foundation

/// How to try what an acpmux session finished (its summary's `tryIt`, from the `try`, `verify` and
/// `report` of its newest wrap-up that gave any; acpmux `hub/try_it.rs`). The workspace row's Try
/// pill opens `url` in a browser tab or runs `command` in a new terminal.
public nonisolated struct AgentLaneTry: Hashable, Sendable {
    public let label: String?
    public let url: String?
    public let command: String?
    public let verify: [String]
    public let report: String?
    /// When the wrap-up that gave it completed: the newest of a workspace's chats wins.
    public let at: Date

    public init(label: String?, url: String?, command: String?, verify: [String], report: String?, at: Date) {
        self.label = label
        self.url = url
        self.command = command
        self.verify = verify
        self.report = report
        self.at = at
    }

    /// The summary's `tryIt` object; nil when absent or empty. A url that is not http(s), or any text
    /// with a control, line-break or bidi character, is dropped here too, as acpmux refuses them: a
    /// command is typed into a terminal, where such a character could run a line other than the one
    /// shown.
    public init?(_ value: Any?) {
        guard let object = value as? [String: Any] else { return nil }
        let text = { (key: String) in (object[key] as? String).flatMap { $0.isEmpty || !Self.isPlainLine($0) ? nil : $0 } }
        let url = text("url").flatMap { URL(string: $0) }.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0.absoluteString : nil }
        let command = text("command")
        let verify = (object["verify"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty && Self.isPlainLine($0) }
        let report = text("report")
        guard url != nil || command != nil || !verify.isEmpty || report != nil else { return nil }
        let at = (object["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? .distantPast
        self.init(label: text("label"), url: url, command: command, verify: verify, report: report, at: at)
    }

    /// Whether `text` is one line with no control (C0, DEL, C1), line or paragraph separator, or bidi
    /// formatting character (acpmux `acpmux_mcp_wrap_up::plain_line`).
    public static func isPlainLine(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0..<0x20, 0x7F...0x9F, 0x2028, 0x2029, 0x200E, 0x200F, 0x061C, 0x202A...0x202E, 0x2066...0x2069: true
            default: false
            }
        }
    }
}
