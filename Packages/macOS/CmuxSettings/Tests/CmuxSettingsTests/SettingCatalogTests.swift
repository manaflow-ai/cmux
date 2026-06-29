import Foundation
import Testing
@testable import CmuxSettings

@Suite("SettingCatalog")
struct SettingCatalogTests {
    @Test func eachKeyHasUniqueId() {
        let ids = SettingCatalog().all.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    @Test func userDefaultsStorageKeysAreUnique() {
        let expectedAliases: [String: Set<String>] = [
            "ampHooksEnabled": [
                "automation.ampIntegration",
                "integrations.amp.hooksEnabled",
            ],
            "claudeCodeCustomClaudePath": [
                "automation.claudeBinaryPath",
                "integrations.claudeCode.customClaudePath",
            ],
            "claudeCodeHooksEnabled": [
                "automation.claudeCodeIntegration",
                "integrations.claudeCode.hooksEnabled",
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
            "suppressSubagentNotifications": [
                "automation.suppressSubagentNotifications",
                "integrations.suppressSubagentNotifications",
            ],
            "sidebarActiveTabIndicatorStyle": [
                "sidebar.activeTabIndicatorStyle",
                "workspaceColors.indicatorStyle",
            ],
            "sidebarNotificationBadgeColorHex": [
                "sidebar.notificationBadgeColor",
                "workspaceColors.notificationBadgeColor",
            ],
            "sidebarSelectionColorHex": [
                "sidebar.selectionColor",
                "workspaceColors.selectionColor",
            ],
        ]

        var idsByStorageKey: [String: Set<String>] = [:]
        for entry in SettingCatalog().all {
            if case let .userDefaults(storageKey, _, _) = entry.kind {
                idsByStorageKey[storageKey, default: []].insert(entry.id)
            }
        }

        let aliases = idsByStorageKey.filter { $0.value.count > 1 }
        #expect(aliases == expectedAliases)

        for storageKey in expectedAliases.keys {
            #expect(idsByStorageKey[storageKey] == expectedAliases[storageKey])
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
        #expect(ids.contains("vault.claudeSessionRoots"))
        #expect(ids.contains("vault.pathMappings"))
    }

    @Test func keyIdsMatchTheirSectionPrefix() {
        // Each key's dotted id must start with its section's prefix; this is
        // the convention that lets the JSON store use `id` as the JSON path.
        let catalog = SettingCatalog()
        for key in catalog.app.all { #expect(key.id.hasPrefix("app.")) }
        for key in catalog.mobile.all { #expect(key.id.hasPrefix("mobile.")) }
        for key in catalog.automation.all { #expect(key.id.hasPrefix("automation.")) }
        for key in catalog.vault.all { #expect(key.id.hasPrefix("vault.")) }
    }
}
