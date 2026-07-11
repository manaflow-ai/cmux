import Foundation
import Testing
@testable import CmuxMobileShell
import CmuxMobileShellModel

@MainActor
@Suite(.serialized) struct MobileTaskTemplateStoreTests {
    @Test func firstListSeedsDefaultTemplatesOnce() {
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)

        #expect(store.listTemplates().map(\.name) == ["Claude", "Codex", "OpenCode", "Shell"])

        store.deleteTemplate(id: store.listTemplates()[0].id)
        let reloaded = UserDefaultsMobileTaskTemplateStore(defaults: defaults)

        #expect(reloaded.listTemplates().map(\.name) == ["Codex", "OpenCode", "Shell"])
    }

    @Test func seedingClearsAbandonedV1Keys() {
        let defaults = Self.defaults()
        defaults.set(Data("stale".utf8), forKey: "cmux.mobile.taskTemplates.v1")
        defaults.set(true, forKey: "cmux.mobile.taskTemplates.seeded.v1")

        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        #expect(store.listTemplates().count == 4)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.v1") == nil)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.seeded.v1") == nil)
    }

    @Test func crudPersistsAcrossStoreInstances() {
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let custom = MobileTaskTemplate(name: "Build", icon: "hammer", command: "swift test", defaultDirectory: "~/dev")

        store.addTemplate(custom)
        var updated = custom
        updated.name = "Test"
        updated.command = "swift test --parallel"
        store.updateTemplate(updated)

        let reloaded = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        #expect(reloaded.listTemplates().contains(updated))

        reloaded.deleteTemplate(id: updated.id)
        #expect(!UserDefaultsMobileTaskTemplateStore(defaults: defaults).listTemplates().contains(updated))
    }

    @Test func deletingAllTemplatesStaysEmptyAfterRelaunch() {
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)

        for template in store.listTemplates() {
            store.deleteTemplate(id: template.id)
        }

        #expect(store.listTemplates().isEmpty)
        #expect(UserDefaultsMobileTaskTemplateStore(defaults: defaults).listTemplates().isEmpty)
    }

    @Test func lastUsedValuesRoundTrip() {
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let templateID = UUID()

        store.setLastTemplateID(templateID)
        store.setLastMacDeviceID("mac-a")
        store.setLastDirectory("~/work", macDeviceID: "mac-a")
        store.setLastDirectory("/tmp/other", macDeviceID: "mac-b")

        let reloaded = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        #expect(reloaded.lastTemplateID() == templateID)
        #expect(reloaded.lastMacDeviceID() == "mac-a")
        #expect(reloaded.lastDirectory(macDeviceID: "mac-a") == "~/work")
        #expect(reloaded.lastDirectory(macDeviceID: "mac-b") == "/tmp/other")

        reloaded.setLastTemplateID(nil)
        reloaded.setLastMacDeviceID(nil)
        reloaded.setLastDirectory(nil, macDeviceID: "mac-a")
        #expect(reloaded.lastTemplateID() == nil)
        #expect(reloaded.lastMacDeviceID() == nil)
        #expect(reloaded.lastDirectory(macDeviceID: "mac-a") == nil)
    }

    @Test func composerDraftRoundTripsAcrossStoreInstancesAndClears() {
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let operationID = UUID()
        let draft = MobileTaskComposerDraft(
            prompt: "Fix the reconnect flow\nthen test it",
            templateID: UUID(),
            macDeviceID: "mac-a",
            directory: "~/Dev/cmux",
            didEditDirectory: true,
            operationID: operationID
        )

        store.setComposerDraft(draft)

        let reloaded = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        #expect(reloaded.composerDraft() == draft)
        #expect(reloaded.composerDraft()?.operationID == operationID)

        reloaded.setComposerDraft(nil)
        #expect(UserDefaultsMobileTaskTemplateStore(defaults: defaults).composerDraft() == nil)
    }

    @Test func signOutClearsPersistedComposerDraftBeforeAnotherAccountCanRestoreIt() {
        let defaults = Self.defaults()
        let templateStore = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        templateStore.setComposerDraft(MobileTaskComposerDraft(
            prompt: "Account A secret",
            templateID: nil,
            macDeviceID: "mac-a",
            directory: "~/Account-A",
            didEditDirectory: true
        ))
        let shell = MobileShellComposite(isSignedIn: true, taskTemplateStore: templateStore)

        shell.signOut()

        #expect(UserDefaultsMobileTaskTemplateStore(defaults: defaults).composerDraft() == nil)
    }

    private static func defaults() -> UserDefaults {
        let suiteName = "MobileTaskTemplateStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
