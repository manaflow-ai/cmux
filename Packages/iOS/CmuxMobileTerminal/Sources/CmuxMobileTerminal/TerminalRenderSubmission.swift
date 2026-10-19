import Foundation

/// Metadata used to match an asynchronous presentation callback to its owner.
struct TerminalRenderSubmission: Equatable, Sendable {
    let token: UInt64
    let generation: UInt64
    let kind: TerminalRenderSubmissionKind
}
