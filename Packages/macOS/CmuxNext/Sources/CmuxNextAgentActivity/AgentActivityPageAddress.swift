public import Foundation

/// `cmux://agent-activity`: the address of the Agent activity page. The pane
/// is a browser tab record with this URL (like `cmux://history`), so it is a
/// tab kind the workspace store already persists and restores.
public nonisolated enum AgentActivityPageAddress {
    public static let string = "cmux://agent-activity"
    /// The page address (a literal a test parses; /dev/null stands in rather than a trap).
    public static let url: URL = URL(string: string) ?? URL(fileURLWithPath: "/dev/null")

    /// `cmux://agent-activity`, with or without a trailing slash, query or fragment.
    public static func matches(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "cmux" else { return false }
        return url.host()?.lowercased() == "agent-activity"
    }
}
