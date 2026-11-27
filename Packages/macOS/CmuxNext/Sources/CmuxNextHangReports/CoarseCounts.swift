/// How much the app had open, as buckets (`0`, `1`, `2-5`, `6-10`, `11-30`, `31-100`, `101+`):
/// enough to tell a light session from a heavy one, never an exact number or a name.
public nonisolated struct CoarseCounts: Codable, Sendable, Equatable {
    /// The bucket of open windows.
    public var windows: String
    /// The bucket of local workspaces.
    public var workspaces: String
    /// The bucket of panes in those workspaces.
    public var panes: String
    /// The bucket of tabs in those panes.
    public var tabs: String

    /// Every label ``bucket(_:)`` returns.
    public static let labels = ["0", "1", "2-5", "6-10", "11-30", "31-100", "101+"]

    /// Counts the app could not read (no window yet).
    public static let unknown = CoarseCounts(windows: 0, workspaces: 0, panes: 0, tabs: 0)

    /// Makes the value from its parts.
    public init(windows: Int, workspaces: Int, panes: Int, tabs: Int) {
        self.windows = Self.bucket(windows)
        self.workspaces = Self.bucket(workspaces)
        self.panes = Self.bucket(panes)
        self.tabs = Self.bucket(tabs)
    }

    /// The bucket label of `count`.
    public static func bucket(_ count: Int) -> String {
        switch count {
        case ..<1: "0"
        case 1: "1"
        case 2...5: "2-5"
        case 6...10: "6-10"
        case 11...30: "11-30"
        case 31...100: "31-100"
        default: "101+"
        }
    }
}
