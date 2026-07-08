import CmuxControlSocket
import Foundation

/// The mobile-host-domain witnesses are the byte-faithful bodies of the former
/// `v2Mobile*` dispatchers `processV2Command` routed.
///
/// These payloads are deeply nested and app-state-derived (render grids,
/// per-workspace terminal lists, the viewport state machine) and resolve their
/// target through `v2ResolveTabManager` / `v2ResolveWorkspace`, and none of them
/// mint `kind:N` refs. So each witness reconstructs the legacy `[String: Any]`
/// params (`JSONValue.foundationObject` is the exact inverse of the bridging the
/// v2 dispatcher applied in `V2SocketRequest(bridging:)`), runs the existing
/// private body unchanged, and bridges the resulting `V2CallResult` to a
/// `ControlCallResult` — the encoded wire bytes are identical.
///
/// Building the result here (in the app target) also keeps the localized
/// terminal-input error strings resolving against the app's
/// `Localizable.xcstrings`: the coordinator never calls `String(localized:)` for
/// this domain, so no non-English translation is dropped.
///
/// These witnesses serve only the v2 control socket (`processV2Command` →
/// ``ControlCommandCoordinator/handleMobileHost(_:)``). The mobile data-plane RPC
/// (`mobileHostHandleRPC`) dispatches the same `v2Mobile*` bodies directly, with
/// no `ControlCallResult` round-trip, so it does not transit this seam.
extension TerminalController: ControlMobileHostContext {
    func controlMobileHostStatus(params: [String: JSONValue]) -> ControlCallResult {
        // `processV2Command` called `v2MobileHostStatus(params:)` with the
        // default `includePrivateMetadata: true`, so keep that here.
        bridgeMobileResult(v2MobileHostStatus(params: foundationParams(params)))
    }

    func controlMobileWorkspaceList(params: [String: JSONValue]) -> ControlCallResult {
        bridgeMobileResult(v2MobileWorkspaceList(params: foundationParams(params)))
    }

    func controlMobileWorkspaceDiffStatus(params: [String: JSONValue]) -> ControlCallResult {
        bridgeMobileResult(v2MobileWorkspaceDiffStatusForControlSocket(params: foundationParams(params)))
    }

    func controlMobileWorkspaceDiffFile(params: [String: JSONValue]) -> ControlCallResult {
        bridgeMobileResult(v2MobileWorkspaceDiffFileForControlSocket(params: foundationParams(params)))
    }

    func controlMobileTerminalCreate(params: [String: JSONValue]) -> ControlCallResult {
        bridgeMobileResult(v2MobileTerminalCreate(params: foundationParams(params)))
    }

    func controlMobileTerminalInput(params: [String: JSONValue]) -> ControlCallResult {
        bridgeMobileResult(v2MobileTerminalInput(params: foundationParams(params)))
    }

    func controlMobileTerminalReplay(params: [String: JSONValue]) -> ControlCallResult {
        bridgeMobileResult(v2MobileTerminalReplay(params: foundationParams(params)))
    }

    func controlMobileTerminalViewport(params: [String: JSONValue]) -> ControlCallResult {
        bridgeMobileResult(v2MobileTerminalViewport(params: foundationParams(params)))
    }

    func controlMobileTerminalScroll(params: [String: JSONValue]) -> ControlCallResult {
        bridgeMobileResult(v2MobileTerminalScroll(params: foundationParams(params)))
    }

    func controlMobileTerminalMouse(params: [String: JSONValue]) -> ControlCallResult {
        bridgeMobileResult(v2MobileTerminalMouse(params: foundationParams(params)))
    }

    func controlMobileTerminalPaste(params: [String: JSONValue]) -> ControlCallResult {
        bridgeMobileResult(v2MobileTerminalPaste(params: foundationParams(params)))
    }

    func controlMobileChatSessionsDump() -> ControlCallResult {
        bridgeMobileResult(v2ChatSessionsDump())
    }

    /// Reconstructs the legacy `[String: Any]` params from the coordinator's
    /// typed params. This is the exact inverse of the dispatcher's
    /// `request.params.mapValues { $0.foundationObject }`, so the legacy body
    /// receives the identical Foundation dictionary it always did.
    private func foundationParams(_ params: [String: JSONValue]) -> [String: Any] {
        params.mapValues(\.foundationObject)
    }

    /// Bridges a legacy `V2CallResult` (Foundation-shaped payload) to the typed
    /// `ControlCallResult`. The mobile bodies only build valid-JSON payloads, so
    /// the bridge never fails; the empty-object / `nil` fallbacks keep the
    /// conversion total.
    private func bridgeMobileResult(_ result: V2CallResult) -> ControlCallResult {
        switch result {
        case let .ok(payload):
            return .ok(JSONValue(foundationObject: payload) ?? .object([:]))
        case let .err(code, message, data):
            return .err(
                code: code,
                message: message,
                data: data.flatMap { JSONValue(foundationObject: $0) }
            )
        }
    }
}
