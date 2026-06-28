import Bonsplit
import CmuxControlSocket
import Foundation

/// The identify-domain witnesses: the live window/workspace/pane/surface graph
/// reads plus the app-bundle paths that back `system.identify`, lifted from the
/// former `TerminalController.v2Identify` (the payload-dict shaping and `kind:N`
/// ref minting now live in ``ControlCommandCoordinator/identify(params:)``).
///
/// Every read is a snapshot; nothing here mutates app state. The coordinator
/// runs on the main actor inside the socket-command policy scope, so the former
/// per-read `v2MainSync` hops collapse to plain in-isolation reads (the same
/// drop the other `Control*Context` witnesses made).
extension TerminalController: ControlIdentifyContext {

    func controlIdentifySocketPath() -> String {
        socketServer.currentSocketPath
    }

    func controlIdentifyFocused(params: [String: JSONValue]) -> ControlIdentifyFocusedSnapshot? {
        let foundationParams = params.mapValues(\.foundationObject)
        guard let tabManager = v2ResolveTabManager(params: foundationParams) else {
            return nil
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        guard let wsId = tabManager.selectedTabId,
              let ws = tabManager.tabs.first(where: { $0.id == wsId }) else {
            return ControlIdentifyFocusedSnapshot(windowID: windowId, selected: nil)
        }
        let paneUUID = ws.bonsplitController.focusedPaneId?.id
        let surfaceUUID = ws.focusedPanelId
        let selected = ControlIdentifyFocusedSnapshot.Selected(
            workspaceID: wsId,
            paneID: paneUUID,
            surfaceID: surfaceUUID,
            surfaceTypeRawValue: surfaceUUID.flatMap { ws.panels[$0]?.panelType.rawValue },
            isBrowserSurface: surfaceUUID.flatMap { ws.panels[$0]?.panelType == .browser }
        )
        return ControlIdentifyFocusedSnapshot(windowID: windowId, selected: selected)
    }

    func controlIdentifyCaller(
        params: [String: JSONValue],
        workspaceID: UUID,
        surfaceID: UUID?
    ) -> ControlIdentifyCallerSnapshot? {
        let foundationParams = params.mapValues(\.foundationObject)
        guard let fallbackTabManager = v2ResolveTabManager(params: foundationParams) else {
            return nil
        }
        let callerTabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID) ?? fallbackTabManager
        guard let ws = callerTabManager.tabs.first(where: { $0.id == workspaceID }) else {
            return nil
        }
        let callerWindowId = v2ResolveWindowId(tabManager: callerTabManager)
        var surface: ControlIdentifyCallerSnapshot.Surface?
        if let surfaceID, ws.panels[surfaceID] != nil {
            let paneUUID = ws.paneId(forPanelId: surfaceID)?.id
            surface = ControlIdentifyCallerSnapshot.Surface(
                surfaceID: surfaceID,
                paneID: paneUUID,
                surfaceTypeRawValue: ws.panels[surfaceID]?.panelType.rawValue,
                isBrowserSurface: ws.panels[surfaceID]?.panelType == .browser
            )
        }
        return ControlIdentifyCallerSnapshot(
            windowID: callerWindowId,
            workspaceID: workspaceID,
            surface: surface
        )
    }

    func controlIdentifyBundle() -> ControlIdentifyBundleSnapshot {
        let cliPath = Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: false)
            .path
        return ControlIdentifyBundleSnapshot(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            bundlePath: Bundle.main.bundleURL.path,
            executablePath: Bundle.main.executableURL?.path,
            cliPath: cliPath
        )
    }
}
