import Foundation

struct AgentMetadataCapture: Sendable {
    let enrichmentTask: Task<Void, Never>
    let processMetadataCaptureTask: Task<Void, Never>

    var value: Void {
        get async { await enrichmentTask.value }
    }
}
