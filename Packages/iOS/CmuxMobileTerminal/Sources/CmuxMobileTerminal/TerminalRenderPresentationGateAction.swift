import Foundation

/// The action produced by a presentation-gate transition.
enum TerminalRenderPresentationGateAction: Equatable {
    case started(TerminalRenderSubmission)
    case queued(TerminalRenderSubmission)
    case ignored
    case idle
}
