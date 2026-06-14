/// Canonical raw kind strings for workspace surfaces.
///
/// These are the wire/persistence identifiers carried on a bonsplit tab's
/// `kind` and serialized into session snapshots, so the string values are
/// frozen. Formerly `Workspace.SurfaceKind` (a case-less namespace enum);
/// lifted as a value-typed namespace per the refactor conventions.
///
/// These are frozen wire/persistence String identifiers (bonsplit tab `kind`,
/// session snapshots) consumed as plain Strings at ~58 call sites; a rawValue
/// enum would change comparison/assignment semantics at the persistence
/// boundary and there is no natural receiver instance.
/// lint:allow namespace-type — frozen String wire identifiers, no receiver.
public struct SurfaceKind {
    /// A Ghostty terminal surface.
    public static let terminal = "terminal"
    /// A browser pane.
    public static let browser = "browser"
    /// A markdown preview pane.
    public static let markdown = "markdown"
    /// A file (Quick Look style) preview pane.
    public static let filePreview = "filePreview"
    /// A right-sidebar tool pane hosted as a surface.
    public static let rightSidebarTool = "rightSidebarTool"
    /// An agent-session pane.
    public static let agentSession = "agentSession"
    /// A project pane.
    public static let project = "project"
    /// A browser pane owned by a sidebar extension.
    public static let extensionBrowser = "extensionBrowser"
}
