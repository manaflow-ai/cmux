internal import Foundation

struct BackendOnlySemanticFrameKey: Equatable {
    let presentationID: UUID
    let presentationGeneration: UInt64
    let terminalSequence: UInt64
}
