/// One surface declared inside a cmux.json custom-layout leaf pane.
///
/// A faithful, `Sendable` image of the app-target `CmuxSurfaceDefinition` fields
/// the layout walk reads. The app-target Codable `CmuxSurfaceDefinition` owns the
/// `cmux.json` wire format; the `applyCustomLayout` forwarding shim maps it onto
/// this value once at the workspace boundary so ``WorkspaceLayoutCoordinator``
/// never imports the app target.
public struct WorkspaceCustomSurface: Sendable {
    /// The kind of surface to create for this entry.
    public enum Kind: Sendable {
        case terminal
        case browser
        case project
    }

    /// The surface kind (`CmuxSurfaceDefinition.type`).
    public var kind: Kind
    /// The custom tab title, if any (`CmuxSurfaceDefinition.name`).
    public var name: String?
    /// A startup command sent to the terminal once ready
    /// (`CmuxSurfaceDefinition.command`).
    public var command: String?
    /// The working directory for a terminal surface, relative to the layout's
    /// base cwd (`CmuxSurfaceDefinition.cwd`).
    public var cwd: String?
    /// Extra startup environment for a terminal surface
    /// (`CmuxSurfaceDefinition.env`).
    public var env: [String: String]?
    /// The URL for a browser surface, or the path for a project surface
    /// (`CmuxSurfaceDefinition.url`).
    public var url: String?
    /// Whether this surface should receive focus after the layout is applied
    /// (`CmuxSurfaceDefinition.focus`).
    public var focus: Bool?

    /// Creates a custom-layout surface value.
    public init(
        kind: Kind,
        name: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        env: [String: String]? = nil,
        url: String? = nil,
        focus: Bool? = nil
    ) {
        self.kind = kind
        self.name = name
        self.command = command
        self.cwd = cwd
        self.env = env
        self.url = url
        self.focus = focus
    }
}
