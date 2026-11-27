import CMUXMobileCore
import CmuxTerminal
import Foundation

/// RPC glue for exactly-once phone input (``MobileHostTerminalInputApplier``).
extension TerminalController {
    /// The delivery identity of a phone request, bound to the terminal the
    /// phone stamped (not the canonical surface it resolves to), so the input
    /// lane bound to the same id and the RPCs share one ledger entry.
    func mobileInputDelivery(params: [String: Any]) -> MobileTerminalInputDelivery? {
        guard let surfaceID = MobileHostRPCRequest.phoneNamedTerminalID(params: params) else { return nil }
        return MobileTerminalInputDelivery.fromRPC(parameters: params, surfaceID: surfaceID)
    }

    /// Checks the ledger before a write. Returns the RPC answer when the unit
    /// must not be written (already applied, out of order, other terminal).
    ///
    /// Every verdict on an identified unit is a successful RPC carrying its
    /// `input_ack`: the phone reads RPC errors as "refused before admission"
    /// and transport errors as "outcome unknown", so a verdict must not look
    /// like either.
    func mobileInputAdmissionAnswer(
        _ delivery: MobileTerminalInputDelivery?,
        workspaceID: UUID,
        surfaceID: UUID
    ) -> V2CallResult? {
        guard let delivery else { return nil }
        guard case .answer(let acknowledgement) = MobileHostTerminalInputApplier.shared.admit(
            delivery,
            surfaceID: delivery.surfaceID
        ) else {
            return nil
        }
        return .ok(acknowledgement.rpcPayload.merging([
            "workspace_id": workspaceID.uuidString,
            "surface_id": surfaceID.uuidString,
        ]) { current, _ in current })
    }

    /// A write the terminal refused. Identified input gets its verdict (busy,
    /// terminal unavailable) as a successful answer; other input keeps the
    /// legacy error.
    func mobileInputWriteFailure(
        code: String,
        message: String,
        surfaceID: UUID,
        acknowledgement: MobileTerminalInputAcknowledgement?
    ) -> V2CallResult {
        guard let acknowledgement else {
            return .err(code: code, message: message, data: ["surface_id": surfaceID.uuidString])
        }
        return .ok(acknowledgement.rpcPayload.merging([
            "surface_id": surfaceID.uuidString,
            "error": code,
        ]) { current, _ in current })
    }

    /// The addressed terminal does not exist. Identified input is answered as
    /// undeliverable so the phone stops resending it and tells the user.
    func mobileInputNotFound(params: [String: Any]) -> V2CallResult {
        guard let acknowledgement = MobileHostTerminalInputApplier.unavailable(
            mobileInputDelivery(params: params)
        ) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        return .ok(acknowledgement.rpcPayload.merging(["error": "not_found"]) { current, _ in current })
    }

    func mobileInputSuccessPayload(
        _ payload: [String: Any],
        acknowledgement: MobileTerminalInputAcknowledgement?
    ) -> [String: Any] {
        guard let acknowledgement else { return payload }
        return payload.merging(acknowledgement.rpcPayload) { current, _ in current }
    }
}

extension TerminalSurface.TextSendResult {
    /// The same outcome in the input-result vocabulary the ledger uses.
    var inputSendResult: TerminalSurface.InputSendResult {
        switch self {
        case .sent: .sent
        case .queued: .queued
        case .inputQueueFull: .inputQueueFull
        case .surfaceUnavailable: .surfaceUnavailable
        case .processExited: .processExited
        }
    }
}
