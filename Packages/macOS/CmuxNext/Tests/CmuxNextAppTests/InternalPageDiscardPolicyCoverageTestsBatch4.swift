import AppKit
@testable import CmuxNextApp
import CmuxHomeCore
import CmuxNextHibernation
@testable import CmuxNextHome
import Testing

/// Page policies batch 4 (p07-memory-027, `memoryDiscardInternalPages`): the Chief pages, the
/// channels Home, the Home tab and the docked Home declare their discard policy and keep reasons,
/// and a Home whose view was discarded shows its conversation and New Message draft again. Each
/// discard runs as the page store runs it (InternalPageTabStore+Show): the provider hears
/// `viewDiscarded`, the tab's next show makes a view, then `restoreViewState` gives it its state.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct InternalPageDiscardPolicyCoverageTestsBatch4 {
    static let conversation = ConversationID("conv_discard_round_trip")
    static let typed = "Lunch at noon?"
    static let recipient = HomeRecipient.address(.email("ada@example.com"))

    /// To: Ada, with text in the blank page's box.
    static var written: HomeNewMessageView.Saved {
        var recipients = HomeNewMessageDraft()
        recipients.add(recipient)
        return HomeNewMessageView.Saved(recipients: recipients, text: typed)
    }

    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    /// `view` in a window, as a pane shows it.
    private static func host(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }

    /// Shows the conversation, then a New Message to Ada with text in its box (as a switch of
    /// recipients carries it); leaves it on screen when `composing`, else goes back to the
    /// conversation (the draft stays with its row).
    private static func writeNewMessage(on page: TopHomePageView, composing: Bool) throws {
        page.show(conversation)
        page.presentNewMessage()
        let draft = try #require(page.newMessage, "New Message shows its page")
        draft.restore(written)
        try #require(draft.saved == written, "the page took the recipients and the text")
        if !composing { page.show(conversation) }
    }

    // MARK: Explicit policy per ID

    @Test func everyPageOfTheBatchDeclaresItsPolicy() {
        let services = Self.services()
        #expect(ChiefViewsPageTab.discardPolicy == .standard)
        #expect(ChiefUsagePageTab.discardPolicy == .standard)
        #expect(HomeChannelsPageTab.make(services).discardPolicy(for: "channels") == .never,
                "the channels page keeps unsent composer text only in the page")
        #expect(ChiefMemoryPageService(services: services).discardPolicy(for: "memory") == .standard)
        #expect(ChiefInspectorPageService(services: services).discardPolicy(for: "inspector") == .standard)
        #expect(HomePageTab(services: services).discardPolicy(for: "home") == .standard)
        #expect(HomeDockTab(services: services).discardPolicy(for: "dock") == .standard)
    }

    // MARK: chiefMemory

    @Test func theMemoryInspectorKeepsItsViewWhileAnEditIsOpen() throws {
        let services = Self.services()
        let service = ChiefMemoryPageService(services: services)
        _ = service.makeView(for: "memory", in: nil)
        let model = try #require(service.model(for: "memory"))
        #expect(service.keepReasons(for: "memory").isEmpty)
        model.beginEdit(.line("0+8"))
        model.draft = "A better summary"
        #expect(service.keepReasons(for: "memory") == [.unsavedEdits], "an edit not saved is never discarded")
        model.cancelEdit()
        #expect(service.keepReasons(for: "memory").isEmpty)
    }

    @Test func aRebuiltMemoryInspectorShowsItsSearchAgain() throws {
        let services = Self.services()
        let service = ChiefMemoryPageService(services: services)
        _ = service.makeView(for: "memory", in: nil)
        try #require(service.model(for: "memory")).query = "deploy"
        service.viewDiscarded("memory")
        #expect(service.model(for: "memory") == nil, "the discarded view's model goes with it")
        let rebuilt = service.makeView(for: "memory", in: nil)
        service.restoreViewState(ContentViewState(), for: "memory", content: rebuilt)
        #expect(service.model(for: "memory")?.query == "deploy")
    }

    // MARK: homeTab

    @Test(arguments: [true, false])
    func aRebuiltHomeTabShowsItsConversationAndNewMessageDraft(composing: Bool) throws {
        let services = Self.services()
        let provider = HomePageTab(services: services)
        let before = try #require(provider.makeView(for: "home", in: nil) as? TopHomePageView)
        let window = Self.host(before)
        defer { window.orderOut(nil) }
        try Self.writeNewMessage(on: before, composing: composing)
        let state = before.viewState
        #expect(state.shown == Self.conversation)
        #expect(state.newMessage == Self.written, "a New Message with text is kept, on screen or not")
        #expect(state.composing == composing)

        provider.viewDiscarded("home")
        #expect(provider.tabs.isEmpty, "the discarded view is no longer the tab's")
        let after = try #require(provider.makeView(for: "home", in: nil) as? TopHomePageView)
        provider.restoreViewState(ContentViewState(), for: "home", content: after)
        #expect(after.viewState == state, "the draft and the shown conversation round-trip")
        #expect(after.newMessage?.saved == Self.written)
        #expect(provider.tabs.map(\.key) == ["home"], "the tab keeps its one place in the order")
    }

    // MARK: homeDock

    @Test func aRebuiltDockShowsItsMessagesDraftAgain() throws {
        let services = Self.services()
        let provider = HomeDockTab(services: services)
        let before = try #require(provider.makeView(for: "dock", in: nil) as? HomeDockView)
        let window = Self.host(before)
        defer { window.orderOut(nil) }
        let messages = try #require(before.messages, "a new dock opens on Messages")
        try Self.writeNewMessage(on: messages, composing: true)
        let state = messages.viewState
        #expect(provider.keepReasons(for: "dock").isEmpty, "a dock without its Channels page holds no page-only input")

        provider.viewDiscarded("dock")
        let after = try #require(provider.makeView(for: "dock", in: nil) as? HomeDockView)
        provider.restoreViewState(ContentViewState(), for: "dock", content: after)
        #expect(after.mode == .messages)
        #expect(after.messages?.viewState == state)
        #expect(after.messages?.newMessage?.saved == Self.written)
    }
}
