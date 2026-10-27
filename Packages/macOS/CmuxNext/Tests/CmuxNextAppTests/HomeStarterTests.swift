import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
import Testing

@MainActor @Suite(.serialized) struct HomeStarterTests {
    @Test func suggestionsReflectAvailableWorkAndStayBounded() {
        let context = HomeStarterContext(workspaces: ["todo-app", "docs", "docs", "site"], working: ["Add search"],
                                         failures: ["Run tests"], pullRequests: ["sample/todo#42"])
        #expect(context.prompts == [HomeStarterStrings.failure("Run tests"), HomeStarterStrings.running("Add search"),
                                    HomeStarterStrings.review("sample/todo#42"), HomeStarterStrings.workspace("todo-app"),
                                    HomeStarterStrings.workspace("docs")])
        #expect(HomeStarterContext().prompts == [HomeStarterStrings.setup, HomeStarterStrings.agent, HomeStarterStrings.task])
        #expect(HomeStarterContext(workspaces: ["todo-app"]).prompts.count == 3)
    }

    @Test func unchangedActivityKeepsButtonsAndChangedActivityReplacesIt() throws {
        let chips = HomeStarterChips(frame: NSRect(x: 0, y: 0, width: 340, height: 200))
        chips.setPrompts(HomeStarterContext(working: ["Add search"]).prompts)
        let original = try #require(chips.buttons.first)
        chips.setPrompts(HomeStarterContext(working: ["Add search"]).prompts)
        #expect(chips.buttons.first === original)
        var sent: [String] = []
        chips.onSend = { sent.append($0) }
        original.performClick(nil)
        #expect(sent == [HomeStarterStrings.running("Add search")])
        chips.isEnabled = false
        original.performClick(nil)
        #expect(sent.count == 1)
        chips.setPrompts(HomeStarterContext(failures: ["Test search"]).prompts)
        #expect(chips.buttons.first?.title == HomeStarterStrings.failure("Test search"))
    }

    @Test func narrowPanesAndLongTranslationsStayAboveComposer() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 280, height: 800))
        panel.starters.setPrompts(HomeStarterContext(workspaces: [String(repeating: "long workspace ", count: 20)],
                                                    working: ["Add search"], failures: ["Run tests"]).prompts)
        for height in stride(from: 800, through: 100, by: -50) {
            panel.setFrameSize(NSSize(width: 280, height: height))
            panel.layoutSubtreeIfNeeded()
            for view in [panel.hero, panel.starters, panel.switchCard] + panel.actionRows where !view.isHiddenOrHasHiddenAncestor {
                #expect(panel.convert(view.bounds, from: view).maxY <= panel.bounds.height + 1)
            }
            for button in panel.starters.buttons {
                #expect(button.frame.maxX <= panel.starters.bounds.width + 1)
            }
        }
    }

    @Test func chipSendsExactlyOnceAndPreservesATypedDraft() async throws {
        let source = MockHomeSource(options: .immediate)
        let chief = await source.chief.id
        let created = try await source.submit(HomeIntent(key: .make(), op: .createGroup(title: "", participants: [chief])))
        let id = try #require(created.conversation)
        let inbox = try await source.inbox()
        let store = HomeStore(source: source)
        store.start()
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: inbox.me.id)
        defer { view.stop(); store.stop() }
        await view.binding.opened()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        view.setFirstRunStarters(HomeStarterContext())
        view.layoutSubtreeIfNeeded()
        let button = try #require(view.firstRun.starters.buttons.first)
        view.showDraft("Keep this draft")
        button.performClick(nil)
        #expect(view.transcript.draftText == "Keep this draft")
        view.showDraft("")
        view.isSendEnabled = false
        button.performClick(nil)
        #expect(view.transcript.draftText.isEmpty)
        view.isSendEnabled = true
        button.performClick(nil)
        button.performClick(nil)
        let deadline = ContinuousClock.now + .seconds(5)
        var sent: [Message] = []
        repeat {
            sent = try await source.snapshot(of: id, tail: 10).messages.filter { $0.author == inbox.me.id }
            if !sent.isEmpty { break }
            await Task.yield()
        } while ContinuousClock.now < deadline
        #expect(sent.count == 1)
        #expect(sent.first?.parts == [.text(HomeStarterStrings.setup)])
    }
}
