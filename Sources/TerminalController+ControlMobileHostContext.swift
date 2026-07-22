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

    func controlHiveOpen(params: [String: JSONValue]) -> ControlCallResult {
        let foundation = foundationParams(params)
        guard let deviceID = foundation["device_id"] as? String, !deviceID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing device_id", data: nil)
        }
        // Same shared action path as the Settings "Open" button and the
        // sidebar scope picker; presentation happens asynchronously.
        HiveComputerMirrorController.presentViewer(deviceID: deviceID)
        return .ok(.object(["started": .bool(true)]))
    }

    func controlHiveRenderProbe() -> ControlCallResult {
        var lines: [String] = []
        let contexts = AppDelegate.shared.map { Array($0.mainWindowContexts.values) } ?? []
        for context in contexts {
            let windowKey = context.window?.isKeyWindow == true ? 1 : 0
            for workspace in context.tabManager.tabs {
                for (panelId, panel) in workspace.panels {
                    guard let terminal = panel as? TerminalPanel else { continue }
                    lines.append(
                        "window=\(context.windowId.uuidString.prefix(8)) key=\(windowKey) "
                        + "workspace=\"\(workspace.title)\" panel=\(panelId.uuidString.prefix(8)) "
                        + terminal.surface.rendererDebugSummary()
                    )
                }
            }
        }
        return .ok(.object(["surfaces": .array(lines.map { .string($0) })]))
    }

    /// `hive.sidebar_probe` (local debug socket) — per-window sidebar scope,
    /// tab counts, and (for a device-scoped window with zero visible tabs)
    /// the resolved connection-status text, mirroring exactly what
    /// `ContentView`'s sidebar body computes. Verifies the blank-sidebar fix
    /// headlessly, without needing Screen Recording permission.
    func controlHiveSidebarProbe() -> ControlCallResult {
        var lines: [String] = []
        let contexts = AppDelegate.shared.map { Array($0.mainWindowContexts.values) } ?? []
        for context in contexts {
            let tabManager = context.tabManager
            let scope = HiveSidebarScopeModel.scopeModel(for: tabManager).scope
            let allTabs = tabManager.tabs
            let visibleTabs = scope == .allComputers
                ? allTabs
                : allTabs.filter {
                    HiveSidebarScopeModel.isVisible(
                        deviceID: HiveComputerMirrorController.shared.deviceID(forWorkspace: $0.id),
                        scope: scope
                    )
                }
            var line = "window=\(context.windowId.uuidString.prefix(8)) scope=\(scope) " +
                "allTabs=\(allTabs.count) visibleTabs=\(visibleTabs.count)"
            if case .device(let deviceID) = scope, visibleTabs.isEmpty {
                let phase = HiveComputersService.shared.connectionPhase(deviceID: deviceID)
                let status = HiveSidebarConnectionStatusView.Status(phase: phase)
                line += " deviceID=\(deviceID.prefix(8)) phase=\(String(describing: phase)) resolvedStatus=\(status)"
            }
            lines.append(line)
        }
        return .ok(.object(["windows": .array(lines.map { .string($0) })]))
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
