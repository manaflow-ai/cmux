import Foundation
import WebKit

@available(macOS 15.4, *)
extension BrowserWebExtensionSupport {
    func restorePermissionState(for context: WKWebExtensionContext, entryID: String, standardizedPath: String) {
        permissionStateStore.state(for: entryID, standardizedPath: standardizedPath)?.apply(to: context)
    }

    func persistPermissionState(entryID: String, standardizedPath: String, context: WKWebExtensionContext) {
        permissionStateStore.save(
            BrowserWebExtensionPermissionState(context: context),
            for: entryID,
            standardizedPath: standardizedPath
        )
    }

    /// Records the user's decision for required manifest access before the
    /// extension loads. Existing grants and denials are preserved, so a
    /// manifest update prompts only for newly requested access.
    func reviewInitialRequiredPermissions(
        for context: WKWebExtensionContext,
        entryID: String,
        standardizedPath: String
    ) {
        let unresolvedPermissions = context.webExtension.requestedPermissions.filter {
            !Self.isResolvedPermissionStatus(context.permissionStatus(for: $0))
        }
        let requiredMatchPatterns = context.webExtension.requestedPermissionMatchPatterns
            .union(context.webExtension.allRequestedMatchPatterns)
        let unresolvedMatchPatterns = requiredMatchPatterns.filter {
            !Self.isResolvedPermissionStatus(context.permissionStatus(for: $0))
        }
        guard !unresolvedPermissions.isEmpty || !unresolvedMatchPatterns.isEmpty else { return }

        var messages: [String] = []
        if !unresolvedPermissions.isEmpty {
            messages.append(permissionMessage(
                extensionContext: context,
                details: unresolvedPermissions.map(\.rawValue).sorted().joined(separator: "\n"),
                key: "browser.webExtension.permissionPrompt.permissions.message",
                defaultValue: "The extension “%@” wants these browser permissions:\n\n%@"
            ))
        }
        if !unresolvedMatchPatterns.isEmpty {
            messages.append(permissionMessage(
                extensionContext: context,
                details: unresolvedMatchPatterns.map(\.string).sorted().joined(separator: "\n"),
                key: "browser.webExtension.permissionPrompt.matchPatterns.message",
                defaultValue: "The extension “%@” wants access to matching pages:\n\n%@"
            ))
        }

        let status: WKWebExtensionContext.PermissionStatus = confirmPermissionRequest(
            informativeText: messages.joined(separator: "\n\n")
        ) ? .grantedExplicitly : .deniedExplicitly
        for permission in unresolvedPermissions {
            context.setPermissionStatus(status, for: permission)
        }
        for matchPattern in unresolvedMatchPatterns {
            context.setPermissionStatus(status, for: matchPattern)
        }
        persistPermissionState(
            entryID: entryID,
            standardizedPath: standardizedPath,
            context: context
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

    private static func isResolvedPermissionStatus(
        _ status: WKWebExtensionContext.PermissionStatus
    ) -> Bool {
        status == .grantedExplicitly ||
            status == .grantedImplicitly ||
            status == .deniedExplicitly ||
            status == .deniedImplicitly
    }
}
