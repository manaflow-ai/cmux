internal import CmuxTerminalBackend
internal import Foundation

struct BackendOnlyAccessibilityDemandAdmission: Equatable, Sendable {
    let requestID: UUID
    let presentation: BackendOnlyAccessibilityDemandPresentation
    let demandGeneration: UInt64

    var releaseOperation: BackendOnlyAccessibilityDemandOperation {
        .release(
            presentationID: presentation.id,
            expectedGeneration: presentation.generation,
            demandGeneration: demandGeneration
        )
    }
}
