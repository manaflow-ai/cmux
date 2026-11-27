import CmuxCloud
import Foundation

extension TerminalController {
    /// `vm.file_transfer_failure` accepts only its own keys and the trace
    /// metadata. The client budget param never reaches it: the `vm.*`
    /// dispatcher strips it first (CloudRequestBudget.socketClientBudget).
    nonisolated static func socketWorkerFileTransferFailureKeysAllowed(_ params: [String: Any]) -> Bool {
        Set(params.keys).isSubset(of: ["phase", "failure", "error_number", "cloud_operation_id", "cloud_trace_id", "cloud_parent_span_id"])
    }

    /// The params a `vm.*` handler sees and the socket client's budget the
    /// dispatcher binds; see the `vm.` case of the socket worker dispatch.
    nonisolated static func socketWorkerVMDispatch(_ params: [String: Any]) -> (params: [String: Any], seconds: TimeInterval?) {
        CloudRequestBudget.live.socketClientBudget(from: params)
    }

    nonisolated func socketWorkerFileTransferFailureResponse(id: Any?, params: [String: Any]) -> String {
        guard let phaseValue = params["phase"] as? String,
              let phase = CloudOperationPhase(rawValue: phaseValue),
              [.snapshot, .request, .connect, .file, .process, .cleanup].contains(phase),
              let failureValue = params["failure"] as? String,
              let failure = CloudDiagnosticFailure(rawValue: failureValue),
              [.network, .process, .timeout, .storage, .response, .unknown].contains(failure),
              Self.socketWorkerFileTransferFailureKeysAllowed(params) else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.cloudDiagnostics.invalidFailure", defaultValue: "Expected a structured file transfer failure."))
        }
        let errorNumber = Self.socketWorkerInt(params["error_number"])
        guard errorNumber.map({ (-65_535...65_535).contains($0) }) ?? true else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.cloudDiagnostics.invalidErrorNumber", defaultValue: "Invalid file transfer error number."))
        }
        return v2VmCall(id: id, timeoutSeconds: 5) {
            let recorder = await MainActor.run { AppDelegate.shared?.cloudOperations }
            guard let reference = await recorder?.recordFileTransferFailure(phase: phase, failure: failure, errorNumber: errorNumber) else {
                return ["recorded": false]
            }
            return ["recorded": true, "reference": reference]
        }
    }

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
                return try await CloudOperationContext.withCurrent(context) {
                    try await context.withPhase(.operation, work)
                }
            }
            return try await recorder.perform(.resolve(method), foreground: !["vm.list", "vm.status", "vm.stats", "vm.network_get", "vm.agent_updates_get"].contains(method), work)
        }
    }
}
