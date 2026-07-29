/// The presentation lifecycle of a Ghostty renderer owned by a terminal surface.
enum TerminalRendererPresentationPhase: Equatable, Sendable {
    /// Ghostty created a live renderer, but it has not been presented in a real window.
    case awaitingFirstPresentation

    /// The renderer is realized and has completed cmux's presentation transition.
    case presented

    /// The renderer was released before it ever reached a real presentation window.
    case releasedBeforeFirstPresentation

    /// The native renderer resources were released while terminal state stayed alive.
    case released

    var isNativeRendererRealized: Bool {
        switch self {
        case .awaitingFirstPresentation, .presented:
            true
        case .releasedBeforeFirstPresentation, .released:
            false
        }
    }

    var isReleased: Bool {
        self == .releasedBeforeFirstPresentation || self == .released
    }
}
