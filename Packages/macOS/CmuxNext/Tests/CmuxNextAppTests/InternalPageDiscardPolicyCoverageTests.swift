import AppKit
@testable import CmuxNextApp
import CmuxNextHibernation
import CmuxNextPages
import CmuxNextResources
import Foundation
import Testing

/// Every internal page declares how long a hidden tab keeps its view (`memory.discard.internalPages`),
/// what keeps it and what it saves. Batch 1: Settings, Debug Settings, Keyboard Shortcuts, the
/// changelog (What's New), Stats and the Task Manager.
@MainActor @Suite(.serialized)
struct InternalPageDiscardPolicyCoverageTests {
    static let batchOne: [InternalPageID] = [.settings, .debugSettings, .keybindings, .changelog, .stats, .taskManager]

    static func services() -> AppServices {
        let services = TaskManagerActionTests.services()
        ChangelogPageTab.register(services)
        return services
    }

    @Test func everyProviderOfTheBatchDeclaresItsPolicy() {
        let services = Self.services()
        for page in Self.batchOne {
            let provider = services.pages.provider(page)
            #expect(provider != nil, "\(page.rawValue) registers at launch")
            #expect(provider?.discardPolicy.isDeclared == true, "\(page.rawValue) chose its policy instead of the default")
        }
    }

    @Test func theDefaultPolicyIsUndeclared() {
        #expect(!InternalPageDiscardPolicy.undeclared.isDeclared)
        #expect(InternalPageDiscardPolicy.undeclared.hiddenTimeout == InternalPageDiscardPolicy.standard.hiddenTimeout)
    }

    @Test func theTaskManagerIsReleasedAMinuteAfterItHides() throws {
        let services = Self.services()
        let provider = try #require(services.pages.provider(.taskManager))
        #expect(provider.discardPolicy == .afterHidden(.seconds(60)), "it samples every process while a view shows it")
    }

    @Test func settingsKeepsAPreviewItHasNotWritten() {
        #expect(SettingsWindowService.keepReasons(previewing: "appearance.windowOpacity") == [.unsavedEdits])
        #expect(SettingsWindowService.keepReasons(previewing: nil).isEmpty)
    }

    @Test func keyboardShortcutsKeepsItsPageWhileItRecords() async throws {
        let services = Self.services()  // the provider holds it unowned
        let provider = KeybindingsPageProvider(services: services)
        let context = PageCallContext(page: PageDescriptor.keybindings.id)
        #expect(!provider.isRecording)
        _ = try await provider.call("cmux.keybindings.record.start", params: .null, context: context)
        #expect(provider.isRecording, "a page taking the next key presses is not released")
        _ = try await provider.call("cmux.keybindings.record.stop", params: .null, context: context)
        #expect(!provider.isRecording)
        withExtendedLifetime(services) {}
    }

    // MARK: Task Manager view state

    @Test func theTaskManagerSortReadsBackAsItWasWritten() {
        let order = TaskManagerSort.order("-memory,process")
        #expect(order.compactMap(TaskManagerSort.init) == [TaskManagerSort(column: .memory, ascending: false),
                                                           TaskManagerSort(column: .process, ascending: true)])
        #expect(TaskManagerSort.text(order) == "-memory,process")
        #expect(TaskManagerSort.order("-nope,cpu").compactMap(TaskManagerSort.init) == [TaskManagerSort(column: .cpu, ascending: true)])
    }

    @Test func aRebuiltTaskManagerShowsTheSortSelectionAndTopRowItSaved() async {
        let source = TaskManagerMemorySavedTests.Source([TaskManagerSampleSet(resources: TaskManagerMemorySavedTests.resources())])
        let before = TaskManagerModel(source: source, kill: { _ in })
        await before.refresh()
        before.sortOrder = TaskManagerSort.order("-memory")
        let shown = before.rows.dropFirst().map(\.id)
        for key in shown { before.rowShown(key) }
        before.selection = [TaskManagerMemorySavedTests.shell]
        let saved = before.savedView

        let after = TaskManagerModel(source: source, kill: { _ in })
        after.restoreView(saved)
        await after.refresh()
        #expect(TaskManagerSort.text(after.sortOrder) == "-memory")
        #expect(after.selection == [TaskManagerMemorySavedTests.shell], "the selection outlives the first sample")
        #expect(after.scrollTarget == shown.first, "the table scrolls back to the first row it drew")
        #expect(after.rows.map(\.id) == before.rows.map(\.id))
    }
}
