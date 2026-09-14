import Foundation

extension TerminalController {
    nonisolated func v2CloudCall(
        id: Any?, method: String, params: [String: Any],
        timeoutSeconds: TimeInterval = 17 * 60,
        transportUnsupportedMachineID: String? = nil,
        _ work: @escaping () async throws -> [String: Any]
    ) -> String {
        let operationID = params["cloud_operation_id"] as? String
        let traceID = params["cloud_trace_id"] as? String
        let parentSpanID = params["cloud_parent_span_id"] as? String
        return v2VmCall(id: id, timeoutSeconds: timeoutSeconds, transportUnsupportedMachineID: transportUnsupportedMachineID) {
            let recorder = await MainActor.run { AppDelegate.shared?.cloudOperations }
            guard let recorder else { return try await work() }
            if let context = await recorder.reference(operationID: operationID, traceID: traceID, spanID: parentSpanID) {
                return try await CloudOperationContext.$current.withValue(context) {
                    try await context.withPhase(.operation, work)
                }
            }
            return try await recorder.perform(.resolve(method), foreground: !["vm.list", "vm.status", "vm.stats"].contains(method), work)
        }
    }
}
