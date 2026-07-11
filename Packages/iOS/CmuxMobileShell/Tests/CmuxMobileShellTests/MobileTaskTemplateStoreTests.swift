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

    @Test func seedingClearsAbandonedV1AndV2Keys() {
        let defaults = Self.defaults()
        defaults.set(Data("stale".utf8), forKey: "cmux.mobile.taskTemplates.v1")
        defaults.set(true, forKey: "cmux.mobile.taskTemplates.seeded.v1")
        defaults.set(Data("stale".utf8), forKey: "cmux.mobile.taskTemplates.v2")
        defaults.set(true, forKey: "cmux.mobile.taskTemplates.seeded.v2")

        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        #expect(store.listTemplates().count == 4)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.v1") == nil)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.seeded.v1") == nil)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.v2") == nil)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.seeded.v2") == nil)
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

    @Test func signOutClearsAllTemplateDataAndNextListReseedsSafeDefaults() throws {
        let defaults = Self.defaults()
        let templateStore = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let custom = MobileTaskTemplate(
            name: "Account A executable",
            icon: "terminal",
            command: "/Users/account-a/bin/private-agent",
            defaultDirectory: "/Users/account-a/secret"
        )
        templateStore.addTemplate(custom)
        templateStore.setLastTemplateID(custom.id)
        templateStore.setLastMacDeviceID("account-a-mac")
        templateStore.setLastDirectory("/Users/account-a/project", macDeviceID: "account-a-mac")
        templateStore.setLastDirectory("/tmp/account-a", macDeviceID: "other-mac")
        templateStore.setComposerDraft(MobileTaskComposerDraft(
            prompt: "Account A secret",
            templateID: custom.id,
            macDeviceID: "account-a-mac",
            directory: "/Users/account-a/project",
            didEditDirectory: true
        ))
        let shell = MobileShellComposite(isSignedIn: true, taskTemplateStore: templateStore)

        shell.signOut()

        let reloaded = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        #expect(reloaded.lastTemplateID() == nil)
        #expect(reloaded.lastMacDeviceID() == nil)
        #expect(reloaded.lastDirectory(macDeviceID: "account-a-mac") == nil)
        #expect(reloaded.lastDirectory(macDeviceID: "other-mac") == nil)
        #expect(reloaded.composerDraft() == nil)
        let seeds = reloaded.listTemplates()
        #expect(seeds.map(\.command) == ["claude", "codex", "opencode --prompt {prompt}", ""])
        #expect(!seeds.contains(where: { $0.id == custom.id }))
        #expect(!seeds.contains(where: { $0.command.contains("account-a") }))
        #expect(defaults.bool(forKey: "cmux.mobile.taskTemplates.seeded.v3"))
    }

    @Test func staleComposerSheetCannotRepersistDraftAfterSignOut() {
        let defaults = Self.defaults()
        let templateStore = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let shell = MobileShellComposite(isSignedIn: true, taskTemplateStore: templateStore)
        let capturedGeneration = shell.currentSessionGeneration
        let staleDraft = MobileTaskComposerDraft(
            prompt: "Account A secret",
            templateID: nil,
            macDeviceID: "mac-a",
            directory: "~/Account-A",
            didEditDirectory: true,
            operationID: UUID()
        )

        shell.signOut()
        let didPersist = shell.persistTaskComposerDraft(
            staleDraft,
            ifSessionGeneration: capturedGeneration
        )

        #expect(!didPersist)
        #expect(UserDefaultsMobileTaskTemplateStore(defaults: defaults).composerDraft() == nil)
    }

    @Test func staleComposerSheetCannotClearNewSessionDraft() {
        let defaults = Self.defaults()
        let templateStore = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let shell = MobileShellComposite(isSignedIn: true, taskTemplateStore: templateStore)
        let staleGeneration = shell.currentSessionGeneration
        let staleDraft = MobileTaskComposerDraft(
            prompt: "Account A secret",
            templateID: nil,
            macDeviceID: "mac-a",
            directory: "~/Account-A",
            didEditDirectory: true,
            operationID: UUID()
        )
        let currentDraft = MobileTaskComposerDraft(
            prompt: "Account B task",
            templateID: nil,
            macDeviceID: "mac-b",
            directory: "~/Account-B",
            didEditDirectory: true,
            operationID: UUID()
        )

        shell.signOut()
        shell.signIn()
        templateStore.setComposerDraft(currentDraft)
        let didPersist = shell.persistTaskComposerDraft(
            staleDraft,
            ifSessionGeneration: staleGeneration
        )

        #expect(!didPersist)
        #expect(UserDefaultsMobileTaskTemplateStore(defaults: defaults).composerDraft() == currentDraft)
    }

    private static func defaults() -> UserDefaults {
        let suiteName = "MobileTaskTemplateStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
