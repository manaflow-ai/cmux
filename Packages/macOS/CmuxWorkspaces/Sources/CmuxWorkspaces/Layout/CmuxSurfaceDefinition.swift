/// A single surface declared inside a ``CmuxPaneDefinition``.
///
/// Carries the surface kind plus the optional fields a `cmux.json` `layout`
/// entry may set: a display name, a launch command, a working directory,
/// environment overrides, an initial URL, and whether it takes initial focus.
public struct CmuxSurfaceDefinition: Codable, Sendable {
    /// The kind of surface to create.
    public var type: CmuxSurfaceType
    /// An optional display name.
    public var name: String?
    /// An optional launch command.
    public var command: String?
    /// An optional working directory.
    public var cwd: String?
    /// Optional environment overrides.
    public var env: [String: String]?
    /// An optional initial URL (for browser surfaces).
    public var url: String?
    /// Whether this surface takes initial focus.
    public var focus: Bool?

    /// Creates a surface definition. Every field except ``type`` defaults to `nil`,
    /// matching the synthesized memberwise initializer this replaces.
    public init(
        type: CmuxSurfaceType,
        name: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        env: [String: String]? = nil,
        url: String? = nil,
        focus: Bool? = nil
    ) {
        self.type = type
        self.name = name
        self.command = command
        self.cwd = cwd
        self.env = env
        self.url = url
        self.focus = focus
    }
}
