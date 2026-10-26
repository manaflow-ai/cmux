import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextHibernation
import Foundation
import Testing

/// Page policies batch 2 (p07-memory-025): history, bookmarks, passwords, stashed, tasks and
/// workspace todo each declare when their hidden tab's view may go. Passwords goes one minute after
/// it hides and keeps no view state; the todo page keeps its view while an item is edited.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct InternalPageDiscardPolicyCoverageTestsBatch2 {
    @Test func everyPageOfTheBatchDeclaresItsPolicy() throws {
        let files = [
            "TopPages/BrowserAppTopPages.swift": 2, "Passwords/PasswordsPage.swift": 1, "Stash/StashTopPage.swift": 1,
            "Tasks/TasksPageService.swift": 1, "Checklist/WorkspaceTodoPageService.swift": 1,
        ]
        for (file, providers) in files {
            let source = try String(contentsOf: Self.appSources.appending(path: file), encoding: .utf8)
            let declared = source.components(separatedBy: "func discardPolicy(for key: String) -> ContentDiscardPolicy").count - 1
            #expect(declared == providers, "\(file) declares \(declared) discard policies for \(providers) providers")
        }
    }

    @Test func passwordsGoesOneMinuteAfterItHidesAndKeepsNoViewState() async throws {
        let services = Self.services()
        let passwords = PasswordsPageService(services: services, store: SamplePasswordStore())
        #expect(passwords.discardPolicy(for: "any") == .afterHidden(.seconds(60)))
        let rig = Rig(services, passwords)
        _ = try #require(rig.pages.view(for: rig.key))
        rig.show()
        rig.hide()
        #expect(rig.discards.nextCheck == 60, "a hidden Passwords page waits its one minute")

        rig.advance(59)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) != nil, "gone before its minute")

        rig.advance(2)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) == nil, "a hidden Passwords page outlived its minute")
        #expect(rig.cache.phase(of: rig.key) == .hibernated)
        #expect(rig.pages.discarded[rig.key] == ContentViewState(), "a secrets page keeps no search, row or scroll")
    }

    @Test func todoKeepsItsViewWhileAnItemIsEditedAndItsDraftAfter() async throws {
        let services = Self.services()
        let rig = Rig(services, services.workspaceTodo)
        _ = try #require(rig.pages.view(for: rig.key))
        let model = try #require(services.workspaceTodo.models[rig.key])
        model.draft = "call the bank"
        model.editing = "item-1"
        #expect(services.workspaceTodo.keepReasons(for: rig.key) == [.unsavedEdits])
        rig.show()
        rig.hide()
        rig.advance(601)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) != nil, "a todo page lost an item's edit")
        #expect(rig.discards.exemptions[rig.key] == .unsavedEdits)

        model.editing = nil
        #expect(services.workspaceTodo.keepReasons(for: rig.key).isEmpty)
        rig.advance(600)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) == nil)

        _ = try #require(rig.pages.view(for: rig.key))
        #expect(services.workspaceTodo.models[rig.key] === model, "the rebuilt view shows the same checklist model")
        #expect(model.draft == "call the bank", "the unsent draft is lost")
    }

    @Test func tasksKeepsItsViewWhileANewTaskTitleIsTyped() throws {
        let services = Self.services()
        let tasks = TasksPageService(services: services)
        let key = LocalPageTab.makeKey(.tasks)
        let view = tasks.makeView(for: key, in: nil)
        defer { tasks.tabClosed(key) }
        #expect(tasks.discardPolicy(for: key) == .standard)
        #expect(tasks.keepReasons(for: key).isEmpty)
        let field = NSTextField(string: "")
        view.addSubview(field)
        #expect(tasks.keepReasons(for: key).isEmpty, "an empty field keeps nothing")
        field.stringValue = "Write the release notes"
        #expect(tasks.keepReasons(for: key) == [.unsavedEdits])
        tasks.viewDiscarded(key)
        #expect(tasks.keepReasons(for: key).isEmpty)
    }

    @Test func bookmarksGetsItsSearchBackAndDropsASelectionThatNoLongerExists() async throws {
        let services = Self.services()
        let bookmarks = BookmarksTopPage(services: services)
        let rig = Rig(services, bookmarks)
        _ = try #require(rig.pages.view(for: rig.key))
        let first = try #require(bookmarks.pages[rig.key])
        first.model.query = "swift"
        first.model.selection = ["gone-bookmark"]
        rig.show()
        rig.hide()
        rig.advance(601)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) == nil)
        #expect(bookmarks.pages[rig.key] == nil, "the discarded page is still kept")

        let rebuilt = try #require(rig.pages.view(for: rig.key))
        rebuilt.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        rebuilt.layoutSubtreeIfNeeded()
        let second = try #require(bookmarks.pages[rig.key])
        #expect(second !== first)
        #expect(second.model.query == "swift")
        #expect(second.model.folder == first.model.folder)
        #expect(second.model.selection.isEmpty, "a selected bookmark missing from the tree came back")
    }

    // MARK: Rig

    static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/CmuxNextApp")

    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    @MainActor final class Rig {
        let services: AppServices
        let discards: InternalPageDiscards
        let pane = Pane()
        let key: String
        var clock = ContinuousClock.now
        var cache: TabContentCache { services.cache }
        var pages: InternalPageTabStore { services.pages }

        init(_ services: AppServices, _ provider: any InternalPageProvider) {
            self.services = services
            services.pages.register(provider)
            discards = InternalPageDiscards(cache: services.cache, pages: services.pages)
            services.pages.discards = discards
            key = services.pages.open(provider.page, in: "pane-batch2-test", of: DaemonStore())
            discards.now = { [unowned self] in self.clock }
        }

        func show() { cache.present(key, by: pane, presence: .visible) }
        func hide() { cache.withdraw(key, by: pane) }
        func advance(_ seconds: Int64) { clock += .seconds(seconds) }
    }

    @MainActor final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }
}
