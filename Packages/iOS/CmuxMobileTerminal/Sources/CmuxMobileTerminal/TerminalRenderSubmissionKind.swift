import Foundation

/// The kind of state transition represented by one render submission.
///
/// The renderer can receive output, a local scroll mutation, and a verified
/// replay request from different producers. They all have the same lifetime:
/// a request is not complete until its exact token reaches the presentation
/// layer.
enum TerminalRenderSubmissionKind: Equatable, Sendable {
    case ordinary
    case localScroll
    case verifiedReplay
}
