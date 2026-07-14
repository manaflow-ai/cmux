import Foundation

extension SharedLiveAgentIndex {
    struct DestructiveCloseIndexCapture: Sendable {
        let indexTask: Task<RestorableAgentSessionIndex?, Never>
        let processMetadataCaptureTask: Task<Void, Never>

        var value: RestorableAgentSessionIndex? {
            get async { await indexTask.value }
        }
    }
}
