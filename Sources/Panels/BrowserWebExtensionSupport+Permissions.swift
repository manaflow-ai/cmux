import Foundation
import WebKit

@available(macOS 15.4, *)
extension BrowserWebExtensionSupport {
    func restorePermissionState(for context: WKWebExtensionContext, entryID: String, standardizedPath: String) {
        permissionStateStore.state(for: entryID, standardizedPath: standardizedPath)?.apply(to: context)
    }

    /// Grants the manifest-required permission sets the first time an
    /// explicitly configured extension loads — the Safari install model:
    /// adding the extension is consent to what its manifest requires, so APIs
    /// like `storage` work immediately (Bitwarden's and uBlock's popups hang
    /// without it). Runs only while the user has made no permission decisions,
    /// so later revocations stick; optional runtime requests still prompt.
    func grantManifestRequestedPermissionsOnFirstLoad(
        for context: WKWebExtensionContext,
        entryID: String,
        standardizedPath: String
    ) {
        // Granted match patterns accrue from normal browsing (per-site access),
        // so only explicit API-permission grants or any denial count as a user
        // decision that blocks the one-time manifest grant.
        let hasDecisions = !context.grantedPermissions.isEmpty
            || !context.deniedPermissions.isEmpty
            || !context.deniedPermissionMatchPatterns.isEmpty
        guard !hasDecisions else { return }

        let expiration = Date.distantFuture
        var grantedPermissions = context.grantedPermissions
        for permission in context.webExtension.requestedPermissions {
            grantedPermissions[permission] = expiration
        }
        context.grantedPermissions = grantedPermissions

        var grantedPatterns = context.grantedPermissionMatchPatterns
        for pattern in context.webExtension.requestedPermissionMatchPatterns {
            grantedPatterns[pattern] = expiration
        }
        context.grantedPermissionMatchPatterns = grantedPatterns
#if DEBUG
        cmuxDebugLog(
            "browser.webext.permissions grantedManifestRequested id=\(entryID) " +
            "permissions=\(context.grantedPermissions.count) patterns=\(context.grantedPermissionMatchPatterns.count)"
        )
#endif
        persistPermissionState(entryID: entryID, standardizedPath: standardizedPath, context: context)
    }

    func persistPermissionState(entryID: String, standardizedPath: String, context: WKWebExtensionContext) {
        permissionStateStore.save(
            BrowserWebExtensionPermissionState(context: context),
            for: entryID,
            standardizedPath: standardizedPath
        )
    }

    func removePermissionState(entryID: String, standardizedPath: String) {
        permissionStateStore.removeState(for: entryID, standardizedPath: standardizedPath)
    }

    func persistPermissionState(for context: WKWebExtensionContext) {
        guard let record = loadedRecordsInOrder.first(where: { $0.context === context }) else { return }
        persistPermissionState(
            entryID: record.entryID,
            standardizedPath: record.standardizedPath,
            context: context
        )
    }

    func persistPermissionStateSoon(for context: WKWebExtensionContext) {
        Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            self.persistPermissionState(for: context)
        }
    }

    func installPermissionStateObservers(
        for context: WKWebExtensionContext,
        entryID: String,
        standardizedPath: String
    ) {
        removePermissionStateObservers(entryID: entryID)
        permissionObserverTokensByEntryID[entryID] = permissionStateNotificationNames.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: context,
                queue: .main
            ) { [weak self, weak context] _ in
                guard let self, let context else { return }
                MainActor.assumeIsolated {
                    self.persistPermissionState(
                        entryID: entryID,
                        standardizedPath: standardizedPath,
                        context: context
                    )
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
