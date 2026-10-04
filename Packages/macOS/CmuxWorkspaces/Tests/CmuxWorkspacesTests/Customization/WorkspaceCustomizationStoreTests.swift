import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
@Suite("Workspace customization store", .serialized)
struct WorkspaceCustomizationStoreTests {
    @Test("persists independent title and color state by stable workspace id")
    func persistenceAndFieldIndependence() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let firstId = UUID()
        let secondId = UUID()

        fixture.store.setCustomTitle("First", for: firstId)
        fixture.store.setCustomColor("#123456", for: secondId)

        let reloaded = WorkspaceCustomizationStore(
            defaults: fixture.defaults,
            storageKey: fixture.storageKey,
            legacyStorageKey: fixture.legacyStorageKey
        )
        #expect(
            reloaded.customization(for: firstId) ==
                WorkspaceCustomization(
                    customTitle: .value("First"),
                    customColor: .absent
                )
        )
        #expect(
            reloaded.customization(for: secondId) ==
                WorkspaceCustomization(
                    customTitle: .absent,
                    customColor: .value("#123456")
                )
        )
    }

    @Test("explicit clears persist as field-specific tombstones")
    func explicitClears() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let stableId = UUID()

        fixture.store.setCustomTitle("Title", for: stableId)
        fixture.store.setCustomColor("#ABCDEF", for: stableId)
        fixture.store.setCustomTitle(nil, for: stableId)

        #expect(
            fixture.store.customization(for: stableId) ==
                WorkspaceCustomization(
                    customTitle: .cleared,
                    customColor: .value("#ABCDEF")
                )
        )
    }

    @Test("retention is bounded by stable workspace identity")
    func boundedRetention() throws {
        let fixture = try makeFixture(capacity: 2)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let firstId = UUID()
        let secondId = UUID()
        let thirdId = UUID()

        fixture.store.setCustomTitle("First", for: firstId)
        fixture.store.setCustomTitle("Second", for: secondId)
        fixture.store.setCustomColor("#111111", for: firstId)
        fixture.store.setCustomTitle("Third", for: thirdId)

        #expect(fixture.store.customization(for: firstId)?.customColor == .value("#111111"))
        #expect(fixture.store.customization(for: secondId) == nil)
        #expect(fixture.store.customization(for: thirdId)?.customTitle == .value("Third"))
    }

    @Test("legacy migration promotes only supplied unambiguous directory owners")
    func legacyMigration() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let legacy = WorkspaceDirectoryCustomizationStore(
            defaults: fixture.defaults,
            storageKey: fixture.legacyStorageKey
        )
        legacy.setCustomTitle("Unique", for: "/tmp/unique")
        legacy.setCustomColor("#123456", for: "/tmp/unique")
        legacy.setCustomTitle("Ambiguous", for: "/tmp/ambiguous")
        let stableId = UUID()

        fixture.store.migrateLegacyDirectoryCustomizations(
            toStableIdsByDirectory: ["/tmp/unique": stableId]
        )

        #expect(
            fixture.store.customization(for: stableId) ==
                WorkspaceCustomization(
                    customTitle: .value("Unique"),
                    customColor: .value("#123456")
                )
        )
        #expect(fixture.defaults.object(forKey: fixture.legacyStorageKey) == nil)
    }

    private func makeFixture(capacity: Int = 512) throws -> (
        store: WorkspaceCustomizationStore,
        defaults: UserDefaults,
        suiteName: String,
        storageKey: String,
        legacyStorageKey: String
    ) {
        let suiteName = "WorkspaceCustomizationStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let storageKey = "test.workspace-customizations"
        let legacyStorageKey = "test.directory-customizations"
        return (
            WorkspaceCustomizationStore(
                defaults: defaults,
                storageKey: storageKey,
                legacyStorageKey: legacyStorageKey,
                capacity: capacity
            ),
            defaults,
            suiteName,
            storageKey,
            legacyStorageKey
        )
    }
}
