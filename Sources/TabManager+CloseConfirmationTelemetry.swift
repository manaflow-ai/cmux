import AppKit
import Foundation

extension TabManager {
    func recordCloseConfirmationTarget(workspaceIds: [UUID]) {
#if DEBUG
        let joinedWorkspaceIds = workspaceIds.map(\.uuidString).joined(separator: ",")
        UITestRecorder.record([
            "closeConfirmationTargetWindowId": AppDelegate.shared?.windowId(for: self)?.uuidString ?? "",
            "closeConfirmationTargetWorkspaceId": workspaceIds.first?.uuidString ?? "",
            "closeConfirmationTargetWorkspaceIds": joinedWorkspaceIds,
        ])
#endif
    }

    func recordCloseConfirmationSheetPresentation(hostWindow: NSWindow) {
#if DEBUG
        var updates = [
            "closeConfirmationPresentation": "sheet",
            "closeConfirmationAttachedSheet": "1",
        ]
        if let hostWindowId = AppDelegate.shared?.mainWindowId(from: hostWindow)?.uuidString {
            updates["closeConfirmationHostWindowId"] = hostWindowId
        }
        UITestRecorder.record(updates)
#endif
    }

    func recordCloseConfirmationAppModalPresentation(hostWindowHadAttachedSheet: Bool) {
#if DEBUG
        UITestRecorder.record([
            "closeConfirmationPresentation": "appModal",
            "closeConfirmationAttachedSheet": hostWindowHadAttachedSheet ? "1" : "0",
        ])
#endif
    }
}
