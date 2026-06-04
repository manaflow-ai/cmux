import Foundation
import Testing
@testable import CmuxSettings

@Suite("SettingCatalog")
struct SettingCatalogTests {
    @Test func eachKeyHasUniqueId() {
        let ids = SettingCatalog().all.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    @Test func aliasedUserDefaultsKeysAgreeOnValueContract() {
        // The catalog deliberately surfaces some UserDefaults storage keys
        // under two ids (the `automation.*` ↔ `integrations.*` reorg and the
        // `sidebar.*` ↔ `workspaceColors.*` pairs) so two settings UIs stay in
        // sync on one stored value. That aliasing is intentional, so a global
        // "every storage key is unique" assertion is wrong. The real hazard is
        // two entries sharing a (key, suite) while disagreeing on Value type or
        // default — that lets one surface clobber or mis-decode the other.
        // Assert agreement on the value contract instead of uniqueness.
        struct StorageLocation: Hashable {
            let suite: String?
            let key: String
        }
        var contractByLocation: [StorageLocation: AnySettingKey.UserDefaultsValueContract] = [:]
        for entry in SettingCatalog().all {
            guard case let .userDefaults(key, suite, _) = entry.kind else { continue }
            // Every userDefaults entry must carry a contract; a missing one is a
            // bug in AnySettingKey, so fail loudly rather than skipping silently.
            #expect(
                entry.userDefaultsValueContract != nil,
                "UserDefaults entry \(entry.id) is missing a value contract"
            )
            guard let contract = entry.userDefaultsValueContract else { continue }
            let location = StorageLocation(suite: suite, key: key)
            if let existing = contractByLocation[location] {
                #expect(
                    existing == contract,
                    "UserDefaults key \(suite ?? "standard")/\(key) is aliased by catalog entries that disagree on value contract: \(existing) vs \(contract)"
                )
            } else {
                contractByLocation[location] = contract
            }
        }
    }

    @Test func valueContractDistinguishesDisagreeingAliases() {
        // Guards that the contract above has teeth: two entries on one storage
        // key must produce different contracts when their default or Value type
        // differs, and equal contracts when their declarations match. Without
        // this, `aliasedUserDefaultsKeysAgreeOnValueContract` could pass
        // vacuously even if a real disagreement were introduced.
        let base = AnySettingKey(
            DefaultsKey<Bool>(id: "test.a", defaultValue: false, userDefaultsKey: "shared"))
        let differentDefault = AnySettingKey(
            DefaultsKey<Bool>(id: "test.b", defaultValue: true, userDefaultsKey: "shared"))
        let differentType = AnySettingKey(
            DefaultsKey<String>(id: "test.c", defaultValue: "", userDefaultsKey: "shared"))
        let matching = AnySettingKey(
            DefaultsKey<Bool>(id: "test.d", defaultValue: false, userDefaultsKey: "shared"))

        #expect(base.userDefaultsValueContract != differentDefault.userDefaultsValueContract)
        #expect(base.userDefaultsValueContract != differentType.userDefaultsValueContract)
        #expect(base.userDefaultsValueContract == matching.userDefaultsValueContract)

        // Container defaults render through a canonical (sorted-keys) encoding,
        // so two dictionaries with the same contents in a different literal
        // order still produce equal contracts, while differing contents do not.
        let dictOrderA = AnySettingKey(
            DefaultsKey<[String: String]>(
                id: "test.e", defaultValue: ["b": "2", "a": "1"], userDefaultsKey: "dict"))
        let dictOrderB = AnySettingKey(
            DefaultsKey<[String: String]>(
                id: "test.f", defaultValue: ["a": "1", "b": "2"], userDefaultsKey: "dict"))
        let dictDifferent = AnySettingKey(
            DefaultsKey<[String: String]>(
                id: "test.g", defaultValue: ["a": "1", "b": "3"], userDefaultsKey: "dict"))

        #expect(dictOrderA.userDefaultsValueContract == dictOrderB.userDefaultsValueContract)
        #expect(dictOrderA.userDefaultsValueContract != dictDifferent.userDefaultsValueContract)
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
        #expect(ids.contains("automation.socketControlMode"))
        #expect(ids.contains("automation.socketPassword"))
    }

    @Test func keyIdsMatchTheirSectionPrefix() {
        // Each key's dotted id must start with its section's prefix; this is
        // the convention that lets the JSON store use `id` as the JSON path.
        let catalog = SettingCatalog()
        for key in catalog.app.all { #expect(key.id.hasPrefix("app.")) }
        for key in catalog.automation.all { #expect(key.id.hasPrefix("automation.")) }
    }
}
