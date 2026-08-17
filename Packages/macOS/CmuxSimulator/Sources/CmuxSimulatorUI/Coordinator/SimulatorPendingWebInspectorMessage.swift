import Foundation

struct SimulatorPendingWebInspectorMessage {
    let sessionID: UUID
    var nextSequence: Int
    var data: Data
    var isTruncated: Bool
    var requestID: SimulatorWebInspectorJSONRequestID?
    var requestIDParser: SimulatorWebInspectorJSONRequestIDStreamParser

    var retainedByteCount: Int {
        data.count + requestIDParser.retainedByteCount
    }
}
