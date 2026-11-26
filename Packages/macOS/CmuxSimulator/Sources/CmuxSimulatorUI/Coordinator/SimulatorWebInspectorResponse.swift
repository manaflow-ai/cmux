import Foundation

struct SimulatorWebInspectorResponse: Equatable, Identifiable, Sendable {
    let id: UUID
    let requestID: SimulatorWebInspectorJSONRequestID?
    let text: String
    let isTruncated: Bool
}
