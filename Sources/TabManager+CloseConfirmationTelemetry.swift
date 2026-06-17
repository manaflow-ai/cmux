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
        // The sheet attaches after this hook returns, so read the attachment on the
        // next runloop turn while the modal loop is running.
        DispatchQueue.main.async {
            var updates = [
                "closeConfirmationPresentation": "sheet",
                "closeConfirmationAttachedSheet": hostWindow.attachedSheet == nil ? "0" : "1",
            ]
            if let hostWindowId = AppDelegate.shared?.mainWindowId(from: hostWindow)?.uuidString {
                updates["closeConfirmationHostWindowId"] = hostWindowId
            }
            UITestRecorder.record(updates)
        }
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
