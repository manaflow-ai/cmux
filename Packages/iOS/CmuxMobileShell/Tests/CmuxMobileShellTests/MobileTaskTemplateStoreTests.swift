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

    @Test func seedingV4ClearsAbandonedV1V2AndV3Keys() {
        let defaults = Self.defaults()
        defaults.set(Data("stale".utf8), forKey: "cmux.mobile.taskTemplates.v1")
        defaults.set(true, forKey: "cmux.mobile.taskTemplates.seeded.v1")
        defaults.set(Data("stale".utf8), forKey: "cmux.mobile.taskTemplates.v2")
        defaults.set(true, forKey: "cmux.mobile.taskTemplates.seeded.v2")
        defaults.set(Data("stale".utf8), forKey: "cmux.mobile.taskTemplates.v3")
        defaults.set(true, forKey: "cmux.mobile.taskTemplates.seeded.v3")

        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        #expect(store.listTemplates().count == 4)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.v1") == nil)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.seeded.v1") == nil)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.v2") == nil)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.seeded.v2") == nil)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.v3") == nil)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.seeded.v3") == nil)
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

    @Test func batchDeletionPersistsAndClearsTheLastSelection() throws {
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let templates = store.listTemplates()
        let deletedIDs = Set(templates.prefix(2).map(\.id))
        let selectedID = try #require(deletedIDs.first)
        store.setLastTemplateID(selectedID)

        store.deleteTemplates(ids: deletedIDs)

        #expect(Set(store.listTemplates().map(\.id)).isDisjoint(with: deletedIDs))
        #expect(store.listTemplates().count == templates.count - deletedIDs.count)
        #expect(store.lastTemplateID() == nil)
        #expect(UserDefaultsMobileTaskTemplateStore(defaults: defaults).listTemplates() == store.listTemplates())
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

    @Test func recentDirectoriesAreByteExactPromotedBoundedAndMacScoped() {
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let base = Date(timeIntervalSince1970: 1_000)
        let composed = "~/caf\u{00E9}"
        let decomposed = "~/cafe\u{301}"

        store.recordRecentDirectory(composed, macDeviceID: "mac-a", at: base)
        store.recordRecentDirectory(decomposed, macDeviceID: "mac-a", at: base.addingTimeInterval(1))
        store.recordRecentDirectory(composed, macDeviceID: "mac-a", at: base.addingTimeInterval(2))
        store.recordRecentDirectory("~/other", macDeviceID: "mac-b", at: base)

        let byteExact = store.recentDirectories(macDeviceID: "mac-a")
        #expect(byteExact.count == 2)
        #expect(byteExact[0].path == composed)
        #expect(byteExact[0].useCount == 2)
        #expect(Array(byteExact[1].path.utf8) == Array(decomposed.utf8))

        for index in 0..<24 {
            store.recordRecentDirectory("~/project-\(index)", macDeviceID: "mac-a", at: base.addingTimeInterval(Double(index + 3)))
        }

        let reloaded = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let macA = reloaded.recentDirectories(macDeviceID: "mac-a")
        #expect(macA.count == 20)
        #expect(macA.first?.path == "~/project-23")
        #expect(reloaded.recentDirectories(macDeviceID: "mac-b").map(\.path) == ["~/other"])
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
        #expect(seeds.map(\.command) == [
            "claude -- \"$CMUX_TASK_PROMPT\"",
            "codex -- \"$CMUX_TASK_PROMPT\"",
            "opencode --prompt \"$CMUX_TASK_PROMPT\"",
            "",
        ])
        #expect(!seeds.contains(where: { $0.id == custom.id }))
        #expect(!seeds.contains(where: { $0.command.contains("account-a") }))
        #expect(defaults.bool(forKey: "cmux.mobile.taskTemplates.seeded.v4"))
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

    @Test func staleCancelClearCannotEraseNewSessionDraft() {
        let defaults = Self.defaults()
        let templateStore = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let shell = MobileShellComposite(isSignedIn: true, taskTemplateStore: templateStore)
        let staleGeneration = shell.currentSessionGeneration
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
        let didClear = shell.clearTaskComposerDraft(ifSessionGeneration: staleGeneration)

        #expect(!didClear)
        #expect(UserDefaultsMobileTaskTemplateStore(defaults: defaults).composerDraft() == currentDraft)
    }

    @Test func staleAsyncSuccessClearCannotEraseNewSessionDraft() async {
        let defaults = Self.defaults()
        let templateStore = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let shell = MobileShellComposite(isSignedIn: true, taskTemplateStore: templateStore)
        let staleGeneration = shell.currentSessionGeneration
        let currentDraft = MobileTaskComposerDraft(
            prompt: "Account B task",
            templateID: nil,
            macDeviceID: "mac-b",
            directory: "~/Account-B",
            didEditDirectory: true,
            operationID: UUID()
        )
        let completion = AsyncStream<Void>.makeStream()
        let clearAfterSuccess = Task { @MainActor in
            for await _ in completion.stream { break }
            return shell.clearTaskComposerDraft(ifSessionGeneration: staleGeneration)
        }

        shell.signOut()
        shell.signIn()
        templateStore.setComposerDraft(currentDraft)
        completion.continuation.yield()
        completion.continuation.finish()
        let didClear = await clearAfterSuccess.value

        #expect(!didClear)
        #expect(UserDefaultsMobileTaskTemplateStore(defaults: defaults).composerDraft() == currentDraft)
    }

    @Test func staleComposerSuccessCannotOverwriteNextSessionDefaults() {
        let defaults = Self.defaults()
        let templateStore = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let shell = MobileShellComposite(isSignedIn: true, taskTemplateStore: templateStore)
        let staleGeneration = shell.currentSessionGeneration
        let accountATemplate = MobileTaskTemplate(
            name: "Account A",
            icon: "terminal",
            command: "agent-a"
        )
        let staleSnapshot = MobileTaskSubmissionSnapshot(
            template: accountATemplate,
            prompt: "Account A task",
            macDeviceID: "mac-a",
            directory: "/Users/account-a/private",
            didEditDirectory: true,
            operationID: UUID()
        )

        shell.signOut()
        shell.signIn()
        let accountBTemplate = MobileTaskTemplate(
            name: "Account B",
            icon: "terminal",
            command: "agent-b"
        )
        let accountBDraft = MobileTaskComposerDraft(
            prompt: "Account B task",
            templateID: accountBTemplate.id,
            macDeviceID: "mac-b",
            directory: "/Users/account-b/current",
            didEditDirectory: true,
            operationID: UUID()
        )
        templateStore.addTemplate(accountBTemplate)
        templateStore.setLastTemplateID(accountBTemplate.id)
        templateStore.setLastMacDeviceID("mac-b")
        templateStore.setLastDirectory("/Users/account-b/current", macDeviceID: "mac-b")
        templateStore.setComposerDraft(accountBDraft)

        let didComplete = shell.completeTaskComposerSubmission(
            staleSnapshot,
            ifSessionGeneration: staleGeneration
        )

        #expect(!didComplete)
        let reloaded = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        #expect(reloaded.lastTemplateID() == accountBTemplate.id)
        #expect(reloaded.lastMacDeviceID() == "mac-b")
        #expect(reloaded.lastDirectory(macDeviceID: "mac-a") == nil)
        #expect(reloaded.lastDirectory(macDeviceID: "mac-b") == "/Users/account-b/current")
        #expect(reloaded.composerDraft() == accountBDraft)
    }

    @Test func currentComposerSuccessPersistsDefaultsAndClearsDraftTogether() {
        let defaults = Self.defaults()
        let templateStore = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let shell = MobileShellComposite(isSignedIn: true, taskTemplateStore: templateStore)
        let template = MobileTaskTemplate(name: "Agent", icon: "terminal", command: "agent")
        let snapshot = MobileTaskSubmissionSnapshot(
            template: template,
            prompt: "Current task",
            macDeviceID: "mac-current",
            directory: "  ~/current  ",
            didEditDirectory: true,
            operationID: UUID()
        )
        templateStore.setComposerDraft(snapshot.draft)

        let didComplete = shell.completeTaskComposerSubmission(
            snapshot,
            ifSessionGeneration: shell.currentSessionGeneration
        )

        #expect(didComplete)
        let reloaded = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        #expect(reloaded.lastTemplateID() == template.id)
        #expect(reloaded.lastMacDeviceID() == "mac-current")
        #expect(reloaded.lastDirectory(macDeviceID: "mac-current") == "~/current")
        #expect(reloaded.composerDraft() == nil)
    }

    @Test func currentSessionClearRemovesComposerDraft() {
        let defaults = Self.defaults()
        let templateStore = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let shell = MobileShellComposite(isSignedIn: true, taskTemplateStore: templateStore)
        templateStore.setComposerDraft(MobileTaskComposerDraft(
            prompt: "Current task",
            templateID: nil,
            macDeviceID: "mac-a",
            directory: "~/Current",
            didEditDirectory: true,
            operationID: UUID()
        ))

        let didClear = shell.clearTaskComposerDraft(
            ifSessionGeneration: shell.currentSessionGeneration
        )

        #expect(didClear)
        #expect(UserDefaultsMobileTaskTemplateStore(defaults: defaults).composerDraft() == nil)
    }

    private static func defaults() -> UserDefaults {
        let suiteName = "MobileTaskTemplateStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
