import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
@Suite("Workspace directory customization store", .serialized)
struct WorkspaceDirectoryCustomizationStoreTests {
    @Test("persists normalized directory identity across store instances")
    func persistenceAndNormalization() throws {
        let suiteName = "WorkspaceDirectoryCustomizationStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstStore = WorkspaceDirectoryCustomizationStore(
            defaults: defaults,
            storageKey: "test.customizations"
        )
        firstStore.setCustomTitle("Project Alpha", for: "/tmp/project/../project")
        firstStore.setCustomColor("#123456", for: "/tmp/project")

        let reloadedStore = WorkspaceDirectoryCustomizationStore(
            defaults: defaults,
            storageKey: "test.customizations"
        )
        #expect(
            reloadedStore.customization(for: "/tmp/project/") ==
                WorkspaceDirectoryCustomization(
                    customTitle: "Project Alpha",
                    customColor: "#123456"
                )
        )
    }

    @Test("field updates preserve siblings and clearing both removes the record")
    func updatesAndClears() throws {
        let suiteName = "WorkspaceDirectoryCustomizationStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = WorkspaceDirectoryCustomizationStore(
            defaults: defaults,
            storageKey: "test.customizations"
        )
        store.setCustomTitle("Label", for: "/tmp/project")
        store.setCustomColor("#ABCDEF", for: "/tmp/project")
        store.setCustomTitle("Renamed", for: "/tmp/project")

        #expect(
            store.customization(for: "/tmp/project") ==
                WorkspaceDirectoryCustomization(
                    customTitle: "Renamed",
                    customColor: "#ABCDEF"
                )
        )

        store.setCustomTitle(nil, for: "/tmp/project")
        store.setCustomColor(nil, for: "/tmp/project")
        #expect(store.customization(for: "/tmp/project") == nil)
        #expect(defaults.data(forKey: "test.customizations") == nil)
    }

    @Test("batch color updates preserve each directory label")
    func batchColorUpdates() throws {
        let suiteName = "WorkspaceDirectoryCustomizationStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = WorkspaceDirectoryCustomizationStore(
            defaults: defaults,
            storageKey: "test.customizations"
        )
        store.setCustomTitle("First", for: "/tmp/first")
        store.setCustomTitle("Second", for: "/tmp/second")

        store.setCustomColor(
            "#123456",
            forDirectories: ["/tmp/first", "/tmp/second/", "/tmp/second"]
        )

        #expect(
            store.customization(for: "/tmp/first") ==
                WorkspaceDirectoryCustomization(customTitle: "First", customColor: "#123456")
        )
        #expect(
            store.customization(for: "/tmp/second") ==
                WorkspaceDirectoryCustomization(customTitle: "Second", customColor: "#123456")
        )

        store.setCustomColor(nil, forDirectories: ["/tmp/first", "/tmp/second"])
        #expect(store.customization(for: "/tmp/first")?.customTitle == "First")
        #expect(store.customization(for: "/tmp/first")?.customColor == nil)
        #expect(store.customization(for: "/tmp/second")?.customTitle == "Second")
        #expect(store.customization(for: "/tmp/second")?.customColor == nil)
    }
}
