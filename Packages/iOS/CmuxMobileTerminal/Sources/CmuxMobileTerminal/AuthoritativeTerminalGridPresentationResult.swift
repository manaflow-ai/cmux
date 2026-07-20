/// The result of applying one producer-authored terminal grid to the visible iOS surface.
public enum AuthoritativeGridPresentationResult: Equatable, Sendable {
    /// The complete frame atomically replaced the previously visible grid.
    case presented
    /// The frame was older than the currently visible producer revision.
    case ignoredStale
    /// The frame was partial or belonged to a different surface, so a full replay is required.
    case needsFullSnapshot

    /// Only an admitted full frame may change terminal geometry before commit.
    public var allowsViewportMutation: Bool {
        self == .presented
    }
}
