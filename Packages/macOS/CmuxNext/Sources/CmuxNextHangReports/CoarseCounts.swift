/// How much the app had open, as buckets (`0`, `1`, `2-5`, `6-10`, `11-30`, `31-100`, `101+`):
/// enough to tell a light session from a heavy one, never an exact number or a name. The buckets
/// are Rust's (cmux-tui/crates/cmux-hang-report), asked through ``HangReportRules``.
public nonisolated struct CoarseCounts: Codable, Sendable, Equatable {
    /// The bucket of open windows.
    public var windows: String
    /// The bucket of local workspaces.
    public var workspaces: String
    /// The bucket of panes in those workspaces.
    public var panes: String
    /// The bucket of tabs in those panes.
    public var tabs: String

    /// Every bucket label.
    public static let labels = ["0", "1", "2-5", "6-10", "11-30", "31-100", "101+"]

    /// Counts the app could not read (no window yet).
    public static let unknown = CoarseCounts(windows: 0, workspaces: 0, panes: 0, tabs: 0)

    /// The buckets of these counts (every one `0` when the rules do not answer).
    public init(windows: Int, workspaces: Int, panes: Int, tabs: Int) {
        struct Request: Encodable {
            var windows: Int
            var workspaces: Int
            var panes: Int
            var tabs: Int
        }
        struct Reply: Decodable {
            var windows: String
            var workspaces: String
            var panes: String
            var tabs: String
        }
        let reply = HangReportRules.call("counts", Request(windows: windows, workspaces: workspaces, panes: panes, tabs: tabs), as: Reply.self)
        self.windows = reply?.windows ?? "0"
        self.workspaces = reply?.workspaces ?? "0"
        self.panes = reply?.panes ?? "0"
        self.tabs = reply?.tabs ?? "0"
    }
}
