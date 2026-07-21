import CMUXMobileCore
import CmuxBrowser
import Foundation

/// `mobile.browser.*` RPC handlers for streaming and driving Mac browser panels.
extension TerminalController {
    func v2MobileBrowserDispatch(
        method: String,
        params: [String: Any],
        connectionID: UUID?
    ) async -> V2CallResult {
        switch method {
        case "mobile.browser.list":
            return v2MobileBrowserList(params: params)
        case "mobile.browser.stream.start":
            guard let connectionID else {
                return .err(code: "unavailable", message: "Browser streaming requires a mobile connection", data: nil)
            }
            guard let request = mobileBrowserDecode(
                MobileBrowserStreamStartParameters.self,
                params: params
            ) else {
                return .err(code: "invalid_params", message: "Invalid browser stream parameters", data: nil)
            }
            if let viewport = request.viewport,
               MobileBrowserStreamViewportMapping(
                   width: viewport.width,
                   height: viewport.height,
                   scale: viewport.scale
               ) == nil {
                return .err(code: "invalid_params", message: "Invalid browser viewport parameters", data: nil)
            }
            guard let panel = mobileBrowserPanel(id: request.panelID) else {
                return mobileBrowserPanelResolutionError(params: params)
            }
            guard let descriptor = await MobileHostService.shared.mobileBrowserStreamCoordinator.start(
                connectionID: connectionID,
                panel: panel,
                viewport: request.viewport
            ), let payload = MobileBrowserWireEncoder().object(descriptor) else {
                return .err(code: "unavailable", message: "Mobile connection is no longer active", data: nil)
            }
            return .ok(payload)
        case "mobile.browser.viewport":
            guard let connectionID else {
                return .err(code: "unavailable", message: "Browser streaming requires a mobile connection", data: nil)
            }
            guard let request = mobileBrowserDecode(
                MobileBrowserViewportParameters.self,
                params: params
            ), MobileBrowserStreamViewportMapping(
                width: request.viewport.width,
                height: request.viewport.height,
                scale: request.viewport.scale
            ) != nil else {
                return .err(code: "invalid_params", message: "Invalid browser viewport parameters", data: nil)
            }
            guard let panel = mobileBrowserPanel(id: request.panelID) else {
                return .err(code: "not_found", message: "Browser panel not found", data: ["panel_id": request.panelID])
            }
            let coordinator = MobileHostService.shared.mobileBrowserStreamCoordinator
            guard coordinator.hasStream(connectionID: connectionID, panelID: panel.id) else {
                return .err(code: "not_found", message: "Browser stream not found", data: ["panel_id": request.panelID])
            }
            guard coordinator.updateViewport(
                connectionID: connectionID,
                panel: panel,
                viewport: request.viewport
            ) else {
                return .err(code: "unavailable", message: "Browser viewport could not be applied", data: nil)
            }
            return .ok(["ok": true, "panel_id": request.panelID])
        case "mobile.browser.stream.stop":
            guard let connectionID else {
                return .err(code: "unavailable", message: "Browser streaming requires a mobile connection", data: nil)
            }
            guard let panelID = mobileBrowserPanelID(params: params) else {
                return .err(code: "invalid_params", message: "Missing or invalid panel_id", data: nil)
            }
            let stopped = await MobileHostService.shared.mobileBrowserStreamCoordinator.stop(
                connectionID: connectionID,
                panelID: panelID
            )
            return .ok(["stopped": stopped, "panel_id": panelID.uuidString])
        case "mobile.browser.frame.ack":
            guard let connectionID else {
                return .err(code: "unavailable", message: "Browser streaming requires a mobile connection", data: nil)
            }
            guard let panelID = mobileBrowserPanelID(params: params),
                  let sequence = mobileBrowserSequence(params["seq"]) else {
                return .err(code: "invalid_params", message: "Missing or invalid panel_id/seq", data: nil)
            }
            let acknowledged = MobileHostService.shared.mobileBrowserStreamCoordinator.acknowledge(
                connectionID: connectionID,
                panelID: panelID,
                sequence: sequence
            )
            return acknowledged
                ? .ok(["acked": true, "panel_id": panelID.uuidString, "seq": sequence])
                : .err(code: "not_found", message: "Browser stream not found", data: ["panel_id": panelID.uuidString])
        case "mobile.browser.dialog.respond":
            guard let response = mobileBrowserDecode(
                MobileBrowserDialogRespondParameters.self,
                params: params
            ) else {
                return .err(code: "invalid_params", message: "Invalid browser dialog response", data: nil)
            }
            guard let panel = mobileBrowserPanel(id: response.panelID) else {
                return .err(code: "not_found", message: "Browser dialog not found", data: nil)
            }
            guard panel.mobileBrowserDialogBroker.respond(response) else {
                return .err(code: "not_found", message: "Browser dialog not found", data: nil)
            }
            return .ok([
                "ok": true,
                "panel_id": response.panelID,
                "dialog_id": response.dialogID,
            ])
        case "mobile.browser.input.pointer":
            return v2MobileBrowserPointerInput(params: params)
        case "mobile.browser.input.scroll":
            return v2MobileBrowserScrollInput(params: params)
        case "mobile.browser.input.key":
            return v2MobileBrowserKeyInput(params: params)
        case "mobile.browser.input.text":
            return await v2MobileBrowserTextInput(params: params)
        case "mobile.browser.navigate":
            guard let panel = mobileBrowserPanel(params: params) else {
                return mobileBrowserPanelResolutionError(params: params)
            }
            guard let rawURL = v2String(params, "url") else {
                return .err(code: "invalid_params", message: "Missing or invalid url", data: nil)
            }
            panel.navigateSmart(rawURL)
            return .ok(["ok": true, "panel_id": panel.id.uuidString])
        case "mobile.browser.back":
            return v2MobileBrowserNavigation(params: params) { $0.goBack() }
        case "mobile.browser.forward":
            return v2MobileBrowserNavigation(params: params) { $0.goForward() }
        case "mobile.browser.reload":
            return v2MobileBrowserNavigation(params: params) { $0.reload() }
        default:
            return .err(code: "method_not_found", message: "Unknown mobile method", data: ["method": method])
        }
    }

    private func v2MobileBrowserList(params: [String: Any]) -> V2CallResult {
        if v2HasNonNullParam(params, "workspace_id"), v2UUID(params, "workspace_id") == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let workspaces: [Workspace]
        if let workspaceID = v2UUID(params, "workspace_id") {
            guard let manager = v2ResolveTabManager(params: params),
                  let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            workspaces = [workspace]
        } else {
            workspaces = mobileBrowserAllWorkspaces()
        }
        let encoder = MobileBrowserWireEncoder()
        let panels = workspaces.flatMap { workspace in
            orderedPanels(in: workspace).compactMap { panel -> [String: Any]? in
                guard let browser = panel as? BrowserPanel else { return nil }
                return encoder.object(encoder.descriptor(panel: browser))
            }
        }
        return .ok(["panels": panels])
    }

    private func v2MobileBrowserPointerInput(params: [String: Any]) -> V2CallResult {
        guard let input = mobileBrowserDecode(MobileBrowserPointerInput.self, params: params) else {
            return .err(code: "invalid_params", message: "Invalid browser pointer input", data: nil)
        }
        guard let panel = mobileBrowserPanel(id: input.panelID) else {
            return .err(code: "not_found", message: "Browser panel not found", data: ["panel_id": input.panelID])
        }
        do {
            try MobileBrowserInputReplayer().replayPointer(input, in: panel.webView)
            return .ok(["ok": true, "panel_id": input.panelID])
        } catch {
            return .err(code: "invalid_params", message: "Invalid browser pointer input", data: nil)
        }
    }

    private func v2MobileBrowserScrollInput(params: [String: Any]) -> V2CallResult {
        guard let input = mobileBrowserDecode(MobileBrowserScrollInput.self, params: params) else {
            return .err(code: "invalid_params", message: "Invalid browser scroll input", data: nil)
        }
        guard let panel = mobileBrowserPanel(id: input.panelID) else {
            return .err(code: "not_found", message: "Browser panel not found", data: ["panel_id": input.panelID])
        }
        do {
            try MobileBrowserInputReplayer().replayScroll(input, in: panel.webView)
            return .ok(["ok": true, "panel_id": input.panelID])
        } catch {
            return .err(code: "invalid_params", message: "Invalid browser scroll input", data: nil)
        }
    }

    private func v2MobileBrowserKeyInput(params: [String: Any]) -> V2CallResult {
        guard let input = mobileBrowserDecode(MobileBrowserKeyInput.self, params: params) else {
            return .err(code: "invalid_params", message: "Invalid browser key input", data: nil)
        }
        guard let panel = mobileBrowserPanel(id: input.panelID) else {
            return .err(code: "not_found", message: "Browser panel not found", data: ["panel_id": input.panelID])
        }
        do {
            try MobileBrowserInputReplayer().replayKey(input, in: panel.webView)
            return .ok(["ok": true, "panel_id": input.panelID])
        } catch {
            return .err(code: "invalid_params", message: "Invalid browser key input", data: nil)
        }
    }

    private func v2MobileBrowserTextInput(params: [String: Any]) async -> V2CallResult {
        guard let input = mobileBrowserDecode(MobileBrowserTextInput.self, params: params) else {
            return .err(code: "invalid_params", message: "Invalid browser text input", data: nil)
        }
        guard let panel = mobileBrowserPanel(id: input.panelID) else {
            return .err(code: "not_found", message: "Browser panel not found", data: ["panel_id": input.panelID])
        }
        do {
            try await MobileBrowserInputReplayer().replayText(input, in: panel.webView)
            return .ok(["ok": true, "panel_id": input.panelID])
        } catch {
            return .err(code: "invalid_params", message: "Browser text could not be inserted", data: nil)
        }
    }

    private func v2MobileBrowserNavigation(
        params: [String: Any],
        action: (BrowserPanel) -> Void
    ) -> V2CallResult {
        guard let panel = mobileBrowserPanel(params: params) else {
            return mobileBrowserPanelResolutionError(params: params)
        }
        action(panel)
        return .ok(["ok": true, "panel_id": panel.id.uuidString])
    }

    private func mobileBrowserPanelResolutionError(params: [String: Any]) -> V2CallResult {
        if mobileBrowserPanelID(params: params) == nil {
            return .err(code: "invalid_params", message: "Missing or invalid panel_id", data: nil)
        }
        return .err(code: "not_found", message: "Browser panel not found", data: nil)
    }

    private func mobileBrowserPanel(params: [String: Any]) -> BrowserPanel? {
        guard let panelID = mobileBrowserPanelID(params: params) else { return nil }
        return mobileBrowserPanel(id: panelID.uuidString)
    }

    private func mobileBrowserPanel(id rawID: String) -> BrowserPanel? {
        guard let panelID = UUID(uuidString: rawID),
              let located = AppDelegate.shared?.locateSurface(surfaceId: panelID),
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) else {
            return nil
        }
        return workspace.browserPanel(for: panelID)
    }

    private func mobileBrowserPanelID(params: [String: Any]) -> UUID? {
        guard let value = v2RawString(params, "panel_id") else { return nil }
        return UUID(uuidString: value)
    }

    private func mobileBrowserSequence(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        if let value = value as? NSNumber {
            let signed = value.int64Value
            return signed >= 0 ? UInt64(signed) : nil
        }
        return nil
    }

    private func mobileBrowserDecode<Value: Decodable>(
        _ type: Value.Type,
        params: [String: Any]
    ) -> Value? {
        guard JSONSerialization.isValidJSONObject(params),
              let data = try? JSONSerialization.data(withJSONObject: params) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func mobileBrowserAllWorkspaces() -> [Workspace] {
        guard let app = AppDelegate.shared else { return tabManager?.tabs ?? [] }
        var seen = Set<UUID>()
        var workspaces: [Workspace] = []
        for summary in app.listMainWindowSummaries() {
            guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }
            for workspace in manager.tabs where seen.insert(workspace.id).inserted {
                workspaces.append(workspace)
            }
        }
        return workspaces.isEmpty ? (tabManager?.tabs ?? []) : workspaces
    }
}
