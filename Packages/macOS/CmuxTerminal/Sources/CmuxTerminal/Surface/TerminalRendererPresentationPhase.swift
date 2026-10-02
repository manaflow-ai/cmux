/// The presentation lifecycle of a Ghostty renderer owned by a terminal surface.
enum TerminalRendererPresentationPhase: Equatable, Sendable {
    /// Ghostty created a live renderer, but it has not been presented in a real window.
    case awaitingFirstPresentation

    /// The renderer is realized and has completed cmux's presentation transition.
    case presented

    /// The native renderer resources were released while terminal state stayed alive.
    case released

    var isNativeRendererRealized: Bool {
        self != .released
    }
}
