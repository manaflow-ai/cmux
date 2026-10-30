import AppKit
import CmuxHomeCore
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextHibernation
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
@testable import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
import WebKit

/// Page policies batch 4 (`memoryDiscardInternalPages`): the Chief pages, the
/// channels Home, the Home tab and the docked Home declare their discard policy and keep reasons,
/// and a Home whose view was discarded shows what it showed again. Each discard runs as the page
/// store runs it (InternalPageTabStore+Show): the provider hears `viewDiscarded`, the tab's next
/// show makes a view, then `restoreViewState` gives it its state. Part of the shared coverage suite.
extension InternalPageDiscardPolicyCoverageTests {
    static let conversation = ConversationID("conv_discard_round_trip")
    static let typed = "Lunch at noon?"
    static let recipient = HomeRecipient.address(.email("ada@example.com"))

    /// Each page of the batch (as ``batchOne``).
    static let batchFour: [InternalPageID] = [
        ChiefViewsPageTab.page, .chiefUsage, .chiefMemory, .chiefInspector, .homeChannels, .homeTab, .homeDock,
    ]

    /// To: Ada, with text in the blank page's box.
    static var written: HomeNewMessageView.Saved {
        var recipients = HomeNewMessageDraft()
        recipients.add(recipient)
        return HomeNewMessageView.Saved(recipients: recipients, text: typed)
    }

    static func homeServices() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    /// `view` in a window, as a pane shows it, beside a text field that can hold the keyboard.
    private static func host(_ view: NSView) -> (NSWindow, NSTextField) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 760))
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let elsewhere = NSTextField(frame: NSRect(x: 0, y: 720, width: 200, height: 24))
        root.addSubview(view)
        root.addSubview(elsewhere)
        window.contentView = root
        view.layoutSubtreeIfNeeded()
        return (window, elsewhere)
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

    /// Each page of the batch registers at launch and answers ten minutes hidden. The protocol's
    /// default is never (fail closed), as is a WebPageTab's, so a page that leaves its policy out
    /// fails here.
    @Test func everyRegisteredPageOfBatchFourDeclaresItsPolicy() {
        let services = Self.homeServices()
        AppActions.bind(services)
        for page in Self.batchFour {
            let provider = services.pages.provider(page)
            #expect(provider != nil, "\(page.rawValue) registers at launch")
            #expect(provider?.discardPolicy(for: "batch4") == .standard, "\(page.rawValue): ten minutes hidden")
            #expect(provider?.keepReasons(for: "batch4").isEmpty == true, "\(page.rawValue): no view, nothing keeps it")
        }
        #expect(services.pages.provider(.homeChannels) is HomeChannelsPageTab)
    }

    // MARK: Channels: kept only while a composer holds unsent input (Chrome's kFormInteractions)

    /// A Channels page, not loaded, whose keep reasons a test sets as its document or the host would.
    private static func channelsPage() -> PageWebView {
        let configuration = WKWebViewConfiguration()
        return PageWebView(descriptor: PageDescriptor(id: "test.home-channels", resource: "discard", processGroup: .solo, namespaces: []),
                           configuration: configuration, inputReadiness: PageInputReadiness(configuration: configuration),
                           routes: [], route: nil, options: .standard, surface: nil, dynamicResources: nil, pooled: false,
                           load: false, chromium: nil, deadlines: .testing())
    }

    /// The composers' unsent input reaches the host as the page's `draft` keep reason
    /// (`cmux.page.keepAlive`, composerDrafts.ts); the Channels tab and the dock read it from there.
    @Test func aChannelsPageIsKeptOnlyWhileItHoldsUnsentInput() {
        let page = Self.channelsPage()
        #expect(HomeChannelsPageTab.keepReasons(of: nil).isEmpty, "no page, nothing to keep")
        #expect(HomeChannelsPageTab.keepReasons(of: page).isEmpty, "a page that has said nothing holds nothing")
        page.keepReasons.begin(.draft)
        #expect(HomeChannelsPageTab.keepReasons(of: page) == [.formInput])
        page.keepReasons.begin(.confirmation)
        #expect(HomeChannelsPageTab.keepReasons(of: page) == [.formInput, .inProgress], "a sheet it opened keeps it too")
        page.keepReasons.end(.confirmation)
        page.keepReasons.end(.draft)
        #expect(HomeChannelsPageTab.keepReasons(of: page).isEmpty, "a sent or cleared composer lets the page go")
        page.keepReasons.begin(.pageCall)
        #expect(HomeChannelsPageTab.keepReasons(of: page).isEmpty, "a reason that only blocks a freeze lets a discard through")
    }

    @Test func aDockWithNoChannelsPageHasNothingToKeep() throws {
        let services = Self.homeServices()
        let provider = HomeDockTab(services: services)
        let dock = try #require(provider.makeView(for: "dock", in: nil) as? HomeDockView)
        #expect(dock.channels == nil, "a dock opens on Messages")
        #expect(provider.keepReasons(for: "dock").isEmpty, "a visit to Messages with nothing typed does not keep the dock")
    }

    // MARK: chiefMemory

    @Test func theMemoryInspectorKeepsItsViewWhileAnEditIsOpen() throws {
        let services = Self.homeServices()
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

    /// The model searches again on its first reload (ChiefMemoryInspectorModelTests has the hits).
    @Test func aRebuiltMemoryInspectorOpensOnItsNodesAndSearch() throws {
        let services = Self.homeServices()
        let service = ChiefMemoryPageService(services: services)
        _ = service.makeView(for: "memory", in: nil)
        try #require(service.model(for: "memory")).restore(trail: ["0+8", "0+3"], query: "deploy", searched: true)
        service.viewDiscarded("memory")
        #expect(service.model(for: "memory") == nil, "the discarded view's model goes with it")
        _ = service.makeView(for: "memory", in: nil)
        let rebuilt = try #require(service.model(for: "memory"))
        #expect(rebuilt.trail == ["0+8", "0+3"])
        #expect(rebuilt.query == "deploy")
        service.tabClosed("memory")
        _ = service.makeView(for: "memory", in: nil)
        #expect(service.model(for: "memory")?.trail.isEmpty == true, "a closed tab's state goes with it")
    }

    // MARK: chiefInspector

    /// A rebuilt tab asks the server its first view used, never the one a later open named for
    /// another tab.
    @Test func aRebuiltInspectorTabKeepsItsServer() throws {
        let services = Self.homeServices()
        let service = ChiefInspectorPageService(services: services)
        _ = service.makeView(for: "restored", in: nil)
        #expect(service.machine(ofTab: "restored") == nil, "a tab restored at launch waits for the first serving server")
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"inspector-discard","workspace_key":"in1"}"#.utf8))
        let window = WindowController(state: WindowState(record: record), services: services, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        _ = service.open(machineID: "server-b", in: window, focus: false)
        service.viewDiscarded("restored")
        _ = service.makeView(for: "restored", in: nil)
        #expect(service.machine(ofTab: "restored") == nil, "the rebuilt view did not take another window's server")
        _ = service.makeView(for: "opened", in: nil)
        #expect(service.machine(ofTab: "opened") == "server-b", "a new tab takes the server it was opened for")
        service.viewDiscarded("opened")
        _ = service.makeView(for: "opened", in: nil)
        #expect(service.machine(ofTab: "opened") == "server-b")
    }

    // MARK: homeTab

    @Test(arguments: [true, false])
    func aRebuiltHomeTabShowsItsConversationSearchAndNewMessageDraft(composing: Bool) throws {
        let services = Self.homeServices()
        let provider = HomePageTab(services: services)
        let before = try #require(provider.makeView(for: "home", in: nil) as? TopHomePageView)
        let (window, _) = Self.host(before)
        defer { window.orderOut(nil) }
        try Self.writeNewMessage(on: before, composing: composing)
        before.list.setSearch("ada")
        let state = before.viewState
        #expect(state.shown == Self.conversation)
        #expect(state.search == "ada")
        #expect(state.newMessage == Self.written, "a New Message with text is kept, on screen or not")
        #expect(state.composing == composing)

        provider.viewDiscarded("home")
        #expect(provider.tabs.isEmpty, "the discarded view is no longer the tab's")
        let after = try #require(provider.makeView(for: "home", in: nil) as? TopHomePageView)
        let (shown, _) = Self.host(after)
        defer { shown.orderOut(nil) }
        provider.restoreViewState(ContentViewState(), for: "home", content: after)
        let restored = after.viewState
        #expect(restored.shown == state.shown, "the shown conversation round-trips")
        #expect(restored.search == "ada", "the list's search round-trips")
        #expect(restored.newMessage == state.newMessage, "the draft round-trips")
        #expect(restored.composing == composing)
        #expect(after.newMessage?.saved == Self.written)
        #expect(provider.tabs.map(\.key) == ["home"], "the tab keeps its one place in the order")
    }

    /// Showing a discarded tab again is not the person choosing it: a keyboard they put elsewhere
    /// stays there. With nothing holding it, the restored New Message takes it, as a show does.
    @Test(arguments: [true, false])
    func aRestoredNewMessageTakesTheKeyboardOnlyWhenNothingHoldsIt(elsewhereHasIt: Bool) throws {
        let services = Self.homeServices()
        let provider = HomePageTab(services: services)
        let before = try #require(provider.makeView(for: "home", in: nil) as? TopHomePageView)
        let (old, _) = Self.host(before)
        defer { old.orderOut(nil) }
        try Self.writeNewMessage(on: before, composing: true)
        provider.viewDiscarded("home")

        let after = try #require(provider.makeView(for: "home", in: nil) as? TopHomePageView)
        let (window, elsewhere) = Self.host(after)
        defer { window.orderOut(nil) }
        if elsewhereHasIt { window.makeFirstResponder(elsewhere) } else { window.makeFirstResponder(nil) }
        let holder = window.firstResponder
        provider.restoreViewState(ContentViewState(), for: "home", content: after)
        #expect(after.isComposingNewMessage)
        if elsewhereHasIt {
            #expect(window.firstResponder === holder, "the keyboard stays where the person put it")
        } else {
            #expect((window.firstResponder as? NSView)?.isDescendant(of: after) == true, "a free keyboard goes to New Message")
        }
    }

    /// The To: people already have a conversation: its draft is the store's, read live, never a
    /// copy in the saved state, so a message sent from another view while this one was discarded
    /// does not come back.
    @Test func aDiscardedNewMessageNeverBringsBackAConversationsSentDraft() async throws {
        // Its own Chief home, so the Home store's cache is this test's, never a real Chief's.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("discard-dm-\(UUID().uuidString)", isDirectory: true)
        let (services, home) = HomeChiefHostedSettingsTests.withChiefHome(root) {
            let made = Self.homeServices()
            return (made, made.home)
        }
        let me = home.homeSource.me
        let ada = Participant(id: ParticipantID("ada-discard"), kind: .human, displayName: "Ada")
        let dm = ConversationID("conv_dm_ada_discard")
        let at = Date(timeIntervalSince1970: 1_000)
        home.homeSource.publish(.inbox(InboxSnapshot(
            me: me, conversations: [CmuxHomeCore.ConversationSummary(id: dm, participants: [me, ada], createdAt: at, updatedAt: at)], rev: 1)))
        let store = home.homeStore
        store.start()
        let listed = await HomeChiefHostedSettingsTests.eventually { store.summary(dm) != nil && store.me != nil }
        try #require(listed, "the store lists Ada's DM")

        var recipients = HomeNewMessageDraft()
        recipients.add(.contact(HomeContact(id: ada.id, name: "Ada", source: .team)))
        let page = HomeNewMessageView(services: services)
        page.restore(HomeNewMessageView.Saved(recipients: recipients, text: ""))
        try #require(page.existing == dm, "To: Ada shows her DM")
        store.setDraft("Lunch?", for: dm)
        let saved = page.saved
        #expect(saved.text.isEmpty, "the DM's draft stays in the store only")
        page.stop()

        store.setDraft("", for: dm) // sent from the dock or another Home tab
        let rebuilt = HomeNewMessageView(services: services)
        rebuilt.restore(saved)
        #expect(rebuilt.existing == dm)
        #expect((store.draft(for: dm) ?? "").isEmpty, "the sent message did not come back as the DM's draft")
        rebuilt.stop()
    }

    // MARK: homeDock

    @Test func aRebuiltDockShowsItsMessagesDraftAgain() throws {
        let services = Self.homeServices()
        let provider = HomeDockTab(services: services)
        let before = try #require(provider.makeView(for: "dock", in: nil) as? HomeDockView)
        let (window, _) = Self.host(before)
        defer { window.orderOut(nil) }
        let messages = try #require(before.messages, "a new dock opens on Messages")
        try Self.writeNewMessage(on: messages, composing: true)
        let state = messages.viewState
        #expect(provider.keepReasons(for: "dock").isEmpty, "a dock without unsent Channels input holds no page-only input")

        provider.viewDiscarded("dock")
        let after = try #require(provider.makeView(for: "dock", in: nil) as? HomeDockView)
        provider.restoreViewState(ContentViewState(), for: "dock", content: after)
        #expect(after.mode == .messages)
        #expect(after.messages?.viewState.shown == state.shown)
        #expect(after.messages?.viewState.newMessage == state.newMessage)
        #expect(after.messages?.newMessage?.saved == Self.written)
    }

    /// The docked Home as the daemon lists it: its page tab alone in the home workspace.
    private static func seedHomeDock(_ services: AppServices) {
        var page = TabSnapshot(surface: 1, kind: .conversation, title: "Home")
        page.conversation = ConversationTabRef(page: HomeDock.page)
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [page])])
        var workspace = WorkspaceSnapshot(id: 1, key: nil, name: "Home", screens: [screen])
        workspace.kind = "home"
        services.daemon.store.apply(snapshot: DaemonTree(workspaces: [workspace]))
    }

    /// A Home action with no `conversation` (CLI, socket, an agent) acts on the conversation the
    /// dock shows, also while the hidden dock's view is discarded.
    @Test func aGroupActionWithoutAConversationFindsTheDiscardedDocksConversation() throws {
        let services = Self.homeServices()
        try #require(!services.home.dock.isClassic, "the docked Home is the default")
        AppActions.bind(services)
        Self.seedHomeDock(services)
        let tab = try #require(services.home.homeWorkspace.flatMap(HomeDock.pageTab(in:))?.tab, "the store lists the dock's tab")
        let provider = try #require(services.pages.provider(.homeDock) as? HomeDockTab)
        let key = services.pages.storeKey(of: tab.id) ?? tab.id
        let dock = try #require(provider.makeView(for: key, in: nil) as? HomeDockView)
        dock.messages?.show(Self.conversation)
        #expect(AppActions.shownConversation(services) == Self.conversation)

        provider.viewDiscarded(key)
        #expect(HomeDockTab.view(services) == nil, "the dock's view is gone")
        #expect(AppActions.shownConversation(services) == Self.conversation, "the tab still stands for its conversation")
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform("home.muteConversation", invocation: ActionInvocation(origin: .script))
        }
        #expect(refusal != RefusalStrings.homeNotReady, "the action found the conversation without a live view")
    }
}
