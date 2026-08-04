import Foundation
import Testing
@testable import CmuxSettings

@Suite("SettingCatalog")
struct SettingCatalogTests {
    @Test func eachKeyHasUniqueId() {
        let ids = SettingCatalog().all.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    @Test func sharedUserDefaultsStorageKeysHaveCompatibleTypesAndDefaults() throws {
        var entriesByStorageKey: [String: [AnySettingKey]] = [:]
        for entry in SettingCatalog().all {
            if case let .userDefaults(storageKey, _, _) = entry.kind {
                entriesByStorageKey[storageKey, default: []].append(entry)
            }
        }

        for (storageKey, entries) in entriesByStorageKey where entries.count > 1 {
            let reference = entries[0]
            let referenceDefault = try #require(reference.userDefaultsDefaultValue)

            for entry in entries.dropFirst() {
                let defaultValue = try #require(entry.userDefaultsDefaultValue)
                #expect(
                    ObjectIdentifier(type(of: defaultValue)) == ObjectIdentifier(type(of: referenceDefault)),
                    "UserDefaults storage key '\(storageKey)' has different Value types for '\(reference.id)' and '\(entry.id)'"
                )
                #expect(
                    settingDefaultsAreEqual(referenceDefault, defaultValue),
                    "UserDefaults storage key '\(storageKey)' has different defaults for '\(reference.id)' and '\(entry.id)'"
                )
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
        #expect(ids.contains("app.focusHistoryIncludesPanesAndTabs"))
        #expect(ids.contains("paneBorderColor"))
        #expect(ids.contains("activePaneBorderColor"))
        #expect(ids.contains("mobile.iOSPairingHost.enabled"))
        #expect(ids.contains("mobile.artifactFolderAccess"))
        #expect(ids.contains("automation.socketControlMode"))
        #expect(ids.contains("automation.socketPassword"))
    }

    @Test func focusHistoryDefaultsToWorkspacesOnly() {
        #expect(!SettingCatalog().app.focusHistoryIncludesPanesAndTabs.defaultValue)
    }

    @Test func keyIdsMatchTheirSectionPrefix() {
        // Each key's dotted id must start with its section's prefix; this is
        // the convention that lets the JSON store use `id` as the JSON path.
        let catalog = SettingCatalog()
        for key in catalog.app.all { #expect(key.id.hasPrefix("app.")) }
        for key in catalog.mobile.all { #expect(key.id.hasPrefix("mobile.")) }
        for key in catalog.automation.all { #expect(key.id.hasPrefix("automation.")) }
        #expect(catalog.paneChrome.paneBorderColorHex.id == "paneBorderColor")
        #expect(catalog.paneChrome.activePaneBorderColorHex.id == "activePaneBorderColor")
    }

    private func settingDefaultsAreEqual(_ lhs: any Sendable, _ rhs: any Sendable) -> Bool {
        guard let lhs = lhs as? any SettingCodable else { return false }
        return settingDefaultEquals(lhs, rhs)
    }

    private func settingDefaultEquals<Value: SettingCodable>(_ lhs: Value, _ rhs: any Sendable) -> Bool {
        guard let rhs = rhs as? Value else { return false }
        return lhs == rhs
    }
}
