/// Canonical entity classes named by structured projection conflicts.
public enum BackendProjectionNavigationEntityKind: String, Codable, Equatable, Sendable {
    /// A stable logical Swift window.
    case logicalPresentation = "logical-presentation"

    /// A canonical workspace.
    case workspace

    /// A canonical screen.
    case screen

    /// A canonical pane.
    case pane

    /// A canonical surface.
    case surface
}
