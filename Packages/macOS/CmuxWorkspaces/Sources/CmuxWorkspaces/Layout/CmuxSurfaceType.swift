/// The kind of surface a ``CmuxSurfaceDefinition`` creates.
public enum CmuxSurfaceType: String, Codable, Sendable {
    /// A terminal surface.
    case terminal
    /// A browser surface.
    case browser
    /// A project surface.
    case project
}
