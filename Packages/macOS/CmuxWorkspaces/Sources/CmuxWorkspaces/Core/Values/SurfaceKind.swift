/// A workspace surface kind, identified by its frozen wire/persistence string.
///
/// The ``rawValue`` strings are the wire/persistence identifiers carried on a
/// bonsplit tab's `kind` and serialized into session snapshots, so they are
/// frozen. Formerly `Workspace.SurfaceKind` (a case-less namespace enum), then
/// a case-less static-constant struct; modeled here as an instantiable value
/// type whose static members are named ``SurfaceKind`` values. Call sites that
/// need the persisted string read ``rawValue``; the string values are unchanged.
public struct SurfaceKind: RawRepresentable, Hashable, Sendable {
    /// The frozen wire/persistence identifier for this surface kind.
    public let rawValue: String

    /// Creates a surface kind from its frozen wire/persistence identifier.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A Ghostty terminal surface.
    public static let terminal = SurfaceKind(rawValue: "terminal")
    /// A browser pane.
    public static let browser = SurfaceKind(rawValue: "browser")
    /// A markdown preview pane.
    public static let markdown = SurfaceKind(rawValue: "markdown")
    /// A file (Quick Look style) preview pane.
    public static let filePreview = SurfaceKind(rawValue: "filePreview")
    /// A right-sidebar tool pane hosted as a surface.
    public static let rightSidebarTool = SurfaceKind(rawValue: "rightSidebarTool")
    /// A custom sidebar hosted as a Bonsplit pane.
    public static let customSidebar = SurfaceKind(rawValue: "customSidebar")
    /// An agent-session pane.
    public static let agentSession = SurfaceKind(rawValue: "agentSession")
    /// A project pane.
    public static let project = SurfaceKind(rawValue: "project")
    /// An Issue Inbox pane.
    public static let issueInbox = SurfaceKind(rawValue: "issueInbox")
    /// A browser pane owned by a sidebar extension.
    public static let extensionBrowser = SurfaceKind(rawValue: "extensionBrowser")
}
