import Foundation

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

    /// The summary's `tryIt` object; nil when absent or empty. A url that is not http(s) or a command
    /// over one line is dropped here too, as acpmux refuses them.
    public init?(_ value: Any?) {
        guard let object = value as? [String: Any] else { return nil }
        let text = { (key: String) in (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let url = text("url").flatMap { URL(string: $0) }.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0.absoluteString : nil }
        let command = text("command").flatMap { $0.contains("\n") ? nil : $0 }
        let verify = (object["verify"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        let report = text("report")
        guard url != nil || command != nil || !verify.isEmpty || report != nil else { return nil }
        let at = (object["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? .distantPast
        self.init(label: text("label"), url: url, command: command, verify: verify, report: report, at: at)
    }
}
