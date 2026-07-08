import AppKit
import CmuxFleet
import Foundation

enum FleetTaskWorkspaceOpenResult: Equatable {
    case opened(workspaceID: UUID)
    case workspaceUnavailable
    case taskNotFound(String)
}

@MainActor
enum FleetTaskWorkspaceOpener {
    static func openTask(_ taskID: FleetTaskID, engine: FleetEngine? = nil) -> FleetTaskWorkspaceOpenResult {
        let engine = engine ?? FleetAppHost.shared.engine
        switch engine.openTarget(taskID: taskID) {
        case .workspace(let idString):
            guard let workspaceID = UUID(uuidString: idString),
                  let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
                  let workspace = tabManager.tabs.first(where: { $0.id == workspaceID })
            else { return .workspaceUnavailable }
            if let windowID = AppDelegate.shared?.windowId(for: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowID)
            }
            if tabManager.selectedTabId != workspace.id {
                tabManager.selectWorkspace(workspace)
            }
            TerminalController.shared.setActiveTabManager(tabManager)
            return .opened(workspaceID: workspaceID)
        case .noWorkspace:
            return .workspaceUnavailable
        case .notFound:
            return .taskNotFound(taskID.rawValue)
        }
    }
}
