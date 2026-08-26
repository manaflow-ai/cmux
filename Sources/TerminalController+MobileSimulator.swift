import CMUXMobileCore
import CmuxSimulator
import Foundation

extension TerminalController {
    func v2MobileSimulatorDispatch(
        method: String,
        params: [String: Any],
        connectionID: UUID?
    ) async -> V2CallResult {
        switch method {
        case "mobile.simulator.list":
            return v2MobileSimulatorList(params: params, connectionID: connectionID)
        case "mobile.simulator.stream.start":
            guard CmuxFeatureFlags.shared.isSimulatorEnabled else {
                MobileSimulatorDiagnostics.recordStream(
                    panelID: nil,
                    state: .startFailed,
                    ownership: .unknown
                )
                return .err(code: "capability_disabled", message: "Simulator panes are disabled", data: nil)
            }
            guard let connectionID else {
                MobileSimulatorDiagnostics.recordStream(
                    panelID: nil,
                    state: .startFailed,
                    ownership: .unknown
                )
                return .err(code: "unavailable", message: "Simulator streaming requires a mobile connection", data: nil)
            }
            guard let request = mobileSimulatorDecode(
                MobileSimulatorStreamStartParameters.self,
                params: params
            ), let workspaceID = UUID(uuidString: request.workspaceID) else {
                MobileSimulatorDiagnostics.recordStream(
                    panelID: nil,
                    state: .startFailed,
                    ownership: .unknown
                )
                return .err(code: "invalid_params", message: "Invalid simulator stream parameters", data: nil)
            }
            guard let resolved = mobileSimulatorPanel(id: request.panelID, workspaceID: workspaceID) else {
                MobileSimulatorDiagnostics.recordStream(
                    panelID: UUID(uuidString: request.panelID),
                    state: .startFailed,
                    ownership: .unknown
                )
                return mobileSimulatorPanelResolutionError(params: params)
            }
            guard resolved.panel.isFeatureReady else {
                MobileSimulatorDiagnostics.recordStream(
                    panelID: resolved.panel.id,
                    state: .startFailed,
                    ownership: .unknown
                )
                return .err(code: "capability_disabled", message: "Simulator pane is disabled", data: [
                    "panel_id": request.panelID
                ])
            }
            let coordinator = MobileHostService.shared.mobileSimulatorStreamCoordinator
            switch await coordinator.start(
                connectionID: connectionID,
                panel: resolved.panel,
                workspaceID: resolved.workspace.id
            ) {
            case let .started(descriptor):
                guard let payload = MobileSimulatorWireEncoder().object(descriptor) else {
                    return .err(code: "internal_error", message: "Failed to encode simulator descriptor", data: nil)
                }
                return .ok(payload)
            case let .locked(descriptor):
                return .err(
                    code: "locked",
                    message: "Simulator pane is already controlled by another phone",
                    data: MobileSimulatorWireEncoder().object(descriptor)
                )
            case .unavailable:
                return .err(code: "unavailable", message: "Mobile connection is no longer active", data: nil)
            }
        case "mobile.simulator.stream.stop":
            guard let connectionID else {
                return .err(code: "unavailable", message: "Simulator streaming requires a mobile connection", data: nil)
            }
            guard let request = mobileSimulatorDecode(
                MobileSimulatorPanelParameters.self,
                params: params
            ), let panelID = UUID(uuidString: request.panelID) else {
                return .err(code: "invalid_params", message: "Missing or invalid panel_id", data: nil)
            }
            let stopped = await MobileHostService.shared.mobileSimulatorStreamCoordinator.stop(
                connectionID: connectionID,
                panelID: panelID
            )
            return .ok(["stopped": stopped, "panel_id": panelID.uuidString])
        case "mobile.simulator.input.pointer":
            return v2MobileSimulatorPointerInput(params: params, connectionID: connectionID)
        case "mobile.simulator.input.text":
            return v2MobileSimulatorTextInput(params: params, connectionID: connectionID)
        case "mobile.simulator.input.button":
            return v2MobileSimulatorButtonInput(params: params, connectionID: connectionID)
        case "mobile.simulator.devices.list":
            return await v2MobileSimulatorDevicesList(params: params, connectionID: connectionID)
        case "mobile.simulator.device.select":
            return v2MobileSimulatorDeviceSelect(params: params, connectionID: connectionID)
        default:
            return .err(code: "method_not_found", message: "Unknown mobile method", data: ["method": method])
        }
    }

    func mobileSimulatorPanels(in workspace: Workspace) -> [SimulatorPanel] {
        orderedPanels(in: workspace).compactMap { $0 as? SimulatorPanel }
    }

    /// Installed simulators a panel can stream. No ownership gate: every
    /// admitted connection is the same account, and the v2 stream's
    /// last-writer-wins model already lets any of the user's devices steer.
    private func v2MobileSimulatorDevicesList(
        params: [String: Any],
        connectionID: UUID?
    ) async -> V2CallResult {
        guard CmuxFeatureFlags.shared.isSimulatorEnabled else {
            return .err(code: "capability_disabled", message: "Simulator panes are disabled", data: nil)
        }
        guard let panelIDString = v2RawString(params, "panel_id"),
              let workspaceID = v2UUID(params, "workspace_id"),
              let resolved = mobileSimulatorPanel(id: panelIDString, workspaceID: workspaceID) else {
            return mobileSimulatorPanelResolutionError(params: params)
        }
        let coordinator = resolved.panel.coordinator
        // The inventory is discovery-time state; refresh it like the Mac
        // pane's picker does on open, so simulators created after the panel
        // started still appear.
        await coordinator.reloadDevices()
        let selectedID = coordinator.selectedDeviceID
        let devices = coordinator.devices.map { device -> [String: Any] in
            [
                "udid": device.id,
                "name": device.name,
                "runtime_name": device.runtimeName,
                "family": device.family.rawValue,
                "state": device.state.rawValue,
                "is_selected": device.id == selectedID,
            ]
        }
        return .ok(["devices": devices])
    }

    /// Selects (and boots when needed) another simulator for the panel.
    /// Fire-and-forget like the Mac pane's picker: the stream's own status
    /// and config/keyframe flow report progress, and a cold boot can take
    /// far longer than any sane RPC deadline.
    private func v2MobileSimulatorDeviceSelect(
        params: [String: Any],
        connectionID: UUID?
    ) -> V2CallResult {
        guard CmuxFeatureFlags.shared.isSimulatorEnabled else {
            return .err(code: "capability_disabled", message: "Simulator panes are disabled", data: nil)
        }
        guard let panelIDString = v2RawString(params, "panel_id"),
              let workspaceID = v2UUID(params, "workspace_id"),
              let udid = v2RawString(params, "udid"), !udid.isEmpty,
              let resolved = mobileSimulatorPanel(id: panelIDString, workspaceID: workspaceID) else {
            return mobileSimulatorPanelResolutionError(params: params)
        }
        guard resolved.panel.coordinator.devices.contains(where: { $0.id == udid }) else {
            return .err(code: "not_found", message: "Simulator device not found", data: ["udid": udid])
        }
        resolved.panel.coordinator.selectDevice(id: udid)
        return .ok(["ok": true, "panel_id": resolved.panel.id.uuidString, "udid": udid])
    }

    private func v2MobileSimulatorList(params: [String: Any], connectionID: UUID?) -> V2CallResult {
        if v2HasNonNullParam(params, "workspace_id"), v2UUID(params, "workspace_id") == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard CmuxFeatureFlags.shared.isSimulatorEnabled else {
            return .ok(["panels": []])
        }

        let workspaces: [Workspace]
        if let workspaceID = v2UUID(params, "workspace_id") {
            guard let manager = v2ResolveTabManager(params: params),
                  let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            workspaces = [workspace]
        } else {
            workspaces = mobileSimulatorAllWorkspaces()
        }

        let streamCoordinator = MobileHostService.shared.mobileSimulatorStreamCoordinator
        let encoder = MobileSimulatorWireEncoder()
        let panels = workspaces.flatMap { workspace in
            mobileSimulatorPanels(in: workspace).compactMap { panel -> [String: Any]? in
                encoder.object(streamCoordinator.descriptor(
                    panel: panel,
                    currentConnectionID: connectionID
                ) ?? encoder.descriptor(
                    panel: panel,
                    workspaceID: workspace.id,
                    currentConnectionID: connectionID
                ))
            }
        }
        return .ok(["panels": panels])
    }

    private func v2MobileSimulatorPointerInput(
        params: [String: Any],
        connectionID: UUID?
    ) -> V2CallResult {
        guard CmuxFeatureFlags.shared.isSimulatorEnabled else {
            MobileSimulatorDiagnostics.recordInput(
                panelID: nil,
                state: .featureDisabled,
                kind: .pointer
            )
            return .err(code: "capability_disabled", message: "Simulator panes are disabled", data: nil)
        }
        guard let connectionID else {
            MobileSimulatorDiagnostics.recordInput(panelID: nil, state: .unavailable, kind: .pointer)
            return .err(code: "unavailable", message: "Simulator input requires a mobile connection", data: nil)
        }
        guard let input = mobileSimulatorDecode(MobileSimulatorPointerInput.self, params: params),
              let workspaceID = UUID(uuidString: input.workspaceID) else {
            MobileSimulatorDiagnostics.recordInput(
                panelID: v2RawString(params, "panel_id").flatMap(UUID.init(uuidString:)),
                state: .invalidParameters,
                kind: .pointer
            )
            return .err(code: "invalid_params", message: "Invalid simulator pointer input", data: nil)
        }
        let panelID = UUID(uuidString: input.panelID)
        let detail = MobileSimulatorDiagnostics.pointerPhase(input.phase).rawValue
        MobileSimulatorDiagnostics.recordCoordinate(
            panelID: panelID,
            x: input.x,
            y: input.y,
            mapping: .mapped
        )
        MobileSimulatorDiagnostics.recordInput(
            panelID: panelID,
            state: .queued,
            kind: .pointer,
            detail: detail
        )
        guard let resolved = mobileSimulatorPanel(id: input.panelID, workspaceID: workspaceID) else {
            MobileSimulatorDiagnostics.recordInput(
                panelID: panelID,
                state: .panelMissing,
                kind: .pointer,
                detail: detail
            )
            return mobileSimulatorPanelResolutionError(params: params)
        }
        guard mobileSimulatorHasControl(connectionID: connectionID, panel: resolved.panel) else {
            MobileSimulatorDiagnostics.recordInput(
                panelID: resolved.panel.id,
                state: .rejectedLocked,
                kind: .pointer,
                detail: detail
            )
            return mobileSimulatorLockedError(panel: resolved.panel, connectionID: connectionID)
        }
        let point = SimulatorPoint(x: input.x, y: input.y)
        switch input.phase {
        case .tap:
            resolved.panel.coordinator.tap(at: point)
        case .began:
            resolved.panel.coordinator.beginTouch(at: point)
        case .moved:
            resolved.panel.coordinator.moveTouch(to: point)
        case .ended:
            resolved.panel.coordinator.endTouch(at: point)
        }
        MobileSimulatorDiagnostics.recordInput(
            panelID: resolved.panel.id,
            state: .accepted,
            kind: .pointer,
            detail: detail
        )
        return .ok(["ok": true, "panel_id": resolved.panel.id.uuidString])
    }

    private func v2MobileSimulatorTextInput(
        params: [String: Any],
        connectionID: UUID?
    ) -> V2CallResult {
        guard CmuxFeatureFlags.shared.isSimulatorEnabled else {
            MobileSimulatorDiagnostics.recordInput(panelID: nil, state: .featureDisabled, kind: .text)
            return .err(code: "capability_disabled", message: "Simulator panes are disabled", data: nil)
        }
        guard let connectionID else {
            MobileSimulatorDiagnostics.recordInput(panelID: nil, state: .unavailable, kind: .text)
            return .err(code: "unavailable", message: "Simulator input requires a mobile connection", data: nil)
        }
        guard let input = mobileSimulatorDecode(MobileSimulatorTextInput.self, params: params),
              let workspaceID = UUID(uuidString: input.workspaceID) else {
            MobileSimulatorDiagnostics.recordInput(
                panelID: v2RawString(params, "panel_id").flatMap(UUID.init(uuidString:)),
                state: .invalidParameters,
                kind: .text
            )
            return .err(code: "invalid_params", message: "Invalid simulator text input", data: nil)
        }
        let panelID = UUID(uuidString: input.panelID)
        let detail = input.text.utf8.count
        MobileSimulatorDiagnostics.recordInput(
            panelID: panelID,
            state: .queued,
            kind: .text,
            detail: detail
        )
        guard let resolved = mobileSimulatorPanel(id: input.panelID, workspaceID: workspaceID) else {
            MobileSimulatorDiagnostics.recordInput(
                panelID: panelID,
                state: .panelMissing,
                kind: .text,
                detail: detail
            )
            return mobileSimulatorPanelResolutionError(params: params)
        }
        guard mobileSimulatorHasControl(connectionID: connectionID, panel: resolved.panel) else {
            MobileSimulatorDiagnostics.recordInput(
                panelID: resolved.panel.id,
                state: .rejectedLocked,
                kind: .text,
                detail: detail
            )
            return mobileSimulatorLockedError(panel: resolved.panel, connectionID: connectionID)
        }
        switch resolved.panel.coordinator.typeText(input.text) {
        case .success:
            MobileSimulatorDiagnostics.recordInput(
                panelID: resolved.panel.id,
                state: .accepted,
                kind: .text,
                detail: detail
            )
            return .ok(["ok": true, "panel_id": resolved.panel.id.uuidString])
        case .failure:
            MobileSimulatorDiagnostics.recordInput(
                panelID: resolved.panel.id,
                state: .unavailable,
                kind: .text,
                detail: detail
            )
            return .err(code: "unavailable", message: "Simulator text input is unavailable", data: [
                "panel_id": resolved.panel.id.uuidString
            ])
        }
    }

    private func v2MobileSimulatorButtonInput(
        params: [String: Any],
        connectionID: UUID?
    ) -> V2CallResult {
        guard CmuxFeatureFlags.shared.isSimulatorEnabled else {
            MobileSimulatorDiagnostics.recordInput(
                panelID: nil,
                state: .featureDisabled,
                kind: .hardwareButton
            )
            return .err(code: "capability_disabled", message: "Simulator panes are disabled", data: nil)
        }
        guard let connectionID else {
            MobileSimulatorDiagnostics.recordInput(panelID: nil, state: .unavailable, kind: .hardwareButton)
            return .err(code: "unavailable", message: "Simulator input requires a mobile connection", data: nil)
        }
        guard let input = mobileSimulatorDecode(MobileSimulatorButtonInput.self, params: params),
              let workspaceID = UUID(uuidString: input.workspaceID) else {
            MobileSimulatorDiagnostics.recordInput(
                panelID: v2RawString(params, "panel_id").flatMap(UUID.init(uuidString:)),
                state: .invalidParameters,
                kind: .hardwareButton
            )
            return .err(code: "invalid_params", message: "Invalid simulator button input", data: nil)
        }
        let panelID = UUID(uuidString: input.panelID)
        let detail = MobileSimulatorDiagnostics.buttonKind(input.button).rawValue
        MobileSimulatorDiagnostics.recordInput(
            panelID: panelID,
            state: .queued,
            kind: .hardwareButton,
            detail: detail
        )
        guard let resolved = mobileSimulatorPanel(id: input.panelID, workspaceID: workspaceID) else {
            MobileSimulatorDiagnostics.recordInput(
                panelID: panelID,
                state: .panelMissing,
                kind: .hardwareButton,
                detail: detail
            )
            return mobileSimulatorPanelResolutionError(params: params)
        }
        guard mobileSimulatorHasControl(connectionID: connectionID, panel: resolved.panel) else {
            MobileSimulatorDiagnostics.recordInput(
                panelID: resolved.panel.id,
                state: .rejectedLocked,
                kind: .hardwareButton,
                detail: detail
            )
            return mobileSimulatorLockedError(panel: resolved.panel, connectionID: connectionID)
        }
        guard let button = SimulatorHardwareButton(rawValue: input.button.rawValue) else {
            MobileSimulatorDiagnostics.recordInput(
                panelID: resolved.panel.id,
                state: .invalidParameters,
                kind: .hardwareButton,
                detail: detail
            )
            return .err(code: "invalid_params", message: "Unsupported simulator button", data: nil)
        }
        resolved.panel.coordinator.press(button)
        MobileSimulatorDiagnostics.recordInput(
            panelID: resolved.panel.id,
            state: .accepted,
            kind: .hardwareButton,
            detail: detail
        )
        return .ok(["ok": true, "panel_id": resolved.panel.id.uuidString])
    }

    private func mobileSimulatorPanel(
        id rawID: String,
        workspaceID: UUID
    ) -> (panel: SimulatorPanel, workspace: Workspace)? {
        guard let panelID = UUID(uuidString: rawID),
              let located = AppDelegate.shared?.locateSurface(surfaceId: panelID),
              located.workspaceId == workspaceID,
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
              let panel = orderedPanels(in: workspace).first(where: { $0.id == panelID }) as? SimulatorPanel else {
            return nil
        }
        return (panel, workspace)
    }

    private func mobileSimulatorPanelResolutionError(params: [String: Any]) -> V2CallResult {
        guard v2RawString(params, "panel_id").flatMap(UUID.init(uuidString:)) != nil else {
            return .err(code: "invalid_params", message: "Missing or invalid panel_id", data: nil)
        }
        return .err(code: "not_found", message: "Simulator panel not found", data: nil)
    }

    private func mobileSimulatorHasControl(connectionID: UUID, panel: SimulatorPanel) -> Bool {
        MobileHostService.shared.mobileSimulatorStreamCoordinator.hasControl(
            connectionID: connectionID,
            panelID: panel.id
        )
    }

    private func mobileSimulatorLockedError(
        panel: SimulatorPanel,
        connectionID: UUID
    ) -> V2CallResult {
        let descriptor = MobileHostService.shared.mobileSimulatorStreamCoordinator.descriptor(
            panel: panel,
            currentConnectionID: connectionID
        )
        return .err(
            code: "locked",
            message: "Simulator pane is controlled by another phone",
            data: descriptor.flatMap { MobileSimulatorWireEncoder().object($0) }
        )
    }

    private func mobileSimulatorAllWorkspaces() -> [Workspace] {
        guard let app = AppDelegate.shared else { return [] }
        var result: [Workspace] = []
        var seenWindowIDs: Set<UUID> = []
        var seenWorkspaceIDs: Set<UUID> = []
        for summary in app.listMainWindowSummaries() {
            guard seenWindowIDs.insert(summary.windowId).inserted,
                  let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }
            for workspace in manager.tabs where seenWorkspaceIDs.insert(workspace.id).inserted {
                result.append(workspace)
            }
        }
        return result
    }

    private func mobileSimulatorDecode<Value: Decodable>(
        _ type: Value.Type,
        params: [String: Any]
    ) -> Value? {
        guard JSONSerialization.isValidJSONObject(params),
              let data = try? JSONSerialization.data(withJSONObject: params) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}
