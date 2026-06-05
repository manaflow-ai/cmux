import Foundation
import Testing
@testable import CmuxSettings

@Suite("SettingCatalog")
struct SettingCatalogTests {
    @Test func eachKeyHasUniqueId() {
        let ids = SettingCatalog().all.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    @Test func userDefaultsStorageKeysAreUniqueExceptDocumentedAliases() {
        let documentedAliases: [String: Set<String>] = [
            "claudeCodeHooksEnabled": [
                "automation.claudeCodeIntegration",
                "integrations.claudeCode.hooksEnabled",
            ],
            "claudeCodeCustomClaudePath": [
                "automation.claudeBinaryPath",
                "integrations.claudeCode.customClaudePath",
            ],
            "ampHooksEnabled": [
                "automation.ampIntegration",
                "integrations.amp.hooksEnabled",
            ],
            "cursorHooksEnabled": [
                "automation.cursorIntegration",
                "integrations.cursor.hooksEnabled",
            ],
            "geminiHooksEnabled": [
                "automation.geminiIntegration",
                "integrations.gemini.hooksEnabled",
            ],
            "kiroHooksEnabled": [
                "automation.kiroIntegration",
                "integrations.kiro.hooksEnabled",
            ],
            "kiroNotificationLevel": [
                "automation.kiroNotificationLevel",
                "integrations.kiro.notificationLevel",
            ],
            "ripgrepCustomBinaryPath": [
                "automation.ripgrepBinaryPath",
                "integrations.ripgrep.customBinaryPath",
            ],
            "sidebarActiveTabIndicatorStyle": [
                "sidebar.activeTabIndicatorStyle",
                "workspaceColors.indicatorStyle",
            ],
            "sidebarSelectionColorHex": [
                "sidebar.selectionColor",
                "workspaceColors.selectionColor",
            ],
            "sidebarNotificationBadgeColorHex": [
                "sidebar.notificationBadgeColor",
                "workspaceColors.notificationBadgeColor",
            ],
            "suppressSubagentNotifications": [
                "automation.suppressSubagentNotifications",
                "integrations.suppressSubagentNotifications",
            ],
        ]
        var idsByStorageKey: [String: [String]] = [:]
        for entry in SettingCatalog().all {
            if case let .userDefaults(storageKey, _, _) = entry.kind {
                idsByStorageKey[storageKey, default: []].append(entry.id)
            }
        }

        for (storageKey, ids) in idsByStorageKey {
            let idSet = Set(ids)
            if ids.count > 1 {
                #expect(idSet == documentedAliases[storageKey])
            } else {
                #expect(documentedAliases[storageKey] == nil)
            }
        }
    }

    @Test func jsonBackedKeysUseTheirIdAsPath() {
        for entry in SettingCatalog().all where entry.kind == .jsonConfig {
            #expect(!entry.id.isEmpty)
            #expect(entry.id.contains("."))
        }
    }

    @Test func allReachesEverySection() {
        // Sanity check: the recursive Mirror walk picks up keys from every
        // nested section. Concretely, both `app.appearance` and
        // `automation.socketPassword` must appear in `all`.
        let ids = Set(SettingCatalog().all.map(\.id))
        #expect(ids.contains("app.appearance"))
        #expect(ids.contains("mobile.iOSPairingHost.enabled"))
        #expect(ids.contains("automation.socketControlMode"))
        #expect(ids.contains("automation.socketPassword"))
    }

    @Test func keyIdsMatchTheirSectionPrefix() {
        // Each key's dotted id must start with its section's prefix; this is
        // the convention that lets the JSON store use `id` as the JSON path.
        let catalog = SettingCatalog()
        for key in catalog.app.all { #expect(key.id.hasPrefix("app.")) }
        for key in catalog.mobile.all { #expect(key.id.hasPrefix("mobile.")) }
        for key in catalog.automation.all { #expect(key.id.hasPrefix("automation.")) }
    }
}
