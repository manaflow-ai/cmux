/// What ``ReactGrab/toggle(_:)`` did on the page.
public nonisolated enum ReactGrabOutcome: Hashable, Sendable {
    /// The page had no react-grab yet: the library was loaded and turned on.
    case loaded
    /// The page already had react-grab: it was turned off or on.
    case toggled
}
