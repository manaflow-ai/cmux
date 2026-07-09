import Foundation
import WebKit

@available(macOS 15.4, *)
extension BrowserWebExtensionSupport {
    func restorePermissionState(for context: WKWebExtensionContext, entryID: String) {
        permissionStateStore.state(for: entryID)?.apply(to: context)
    }

    func persistPermissionState(entryID: String, context: WKWebExtensionContext) {
        permissionStateStore.save(BrowserWebExtensionPermissionState(context: context), for: entryID)
    }

    func removePermissionState(entryID: String) {
        permissionStateStore.removeState(for: entryID)
    }

    func persistPermissionState(for context: WKWebExtensionContext) {
        guard let record = loadedRecordsInOrder.first(where: { $0.context === context }) else { return }
        persistPermissionState(entryID: record.entryID, context: context)
    }

    func persistPermissionStateSoon(for context: WKWebExtensionContext) {
        Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            self.persistPermissionState(for: context)
        }
    }

    func installPermissionStateObservers(for context: WKWebExtensionContext, entryID: String) {
        removePermissionStateObservers(entryID: entryID)
        permissionObserverTokensByEntryID[entryID] = permissionStateNotificationNames.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: context,
                queue: .main
            ) { [weak self, weak context] _ in
                guard let self, let context else { return }
                MainActor.assumeIsolated {
                    self.persistPermissionState(entryID: entryID, context: context)
                }
            }
        }
    }

    func removePermissionStateObservers(entryID: String) {
        guard let tokens = permissionObserverTokensByEntryID.removeValue(forKey: entryID) else { return }
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func removeAllPermissionStateObservers() {
        for entryID in Array(permissionObserverTokensByEntryID.keys) {
            removePermissionStateObservers(entryID: entryID)
        }
    }

    private var permissionStateNotificationNames: [Notification.Name] {
        [
            WKWebExtensionContext.permissionsWereGrantedNotification,
            WKWebExtensionContext.permissionsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionsWereRemovedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification,
        ]
    }
}
