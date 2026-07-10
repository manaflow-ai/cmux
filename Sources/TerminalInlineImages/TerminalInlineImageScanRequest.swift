import Foundation

/// An immutable render-grid snapshot tied to one active surface presentation session.
struct TerminalInlineImageScanRequest: Sendable {
    let workID: UUID
    let sessionID: UUID
    let surfaceID: UUID
    let gridJSON: Data
    let rowOffset: Int
    let context: TerminalTranscriptImagePathScanner.Context
}
