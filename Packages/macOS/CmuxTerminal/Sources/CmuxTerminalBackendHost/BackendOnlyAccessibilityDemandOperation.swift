internal import CmuxTerminalBackend
internal import Foundation

enum BackendOnlyAccessibilityDemandOperation: Equatable, Sendable {
    case acquire(
        requestID: UUID,
        presentationID: PresentationID,
        expectedGeneration: UInt64,
        expectedDemandGeneration: UInt64?
    )
    case release(
        presentationID: PresentationID,
        expectedGeneration: UInt64,
        demandGeneration: UInt64
    )
}
