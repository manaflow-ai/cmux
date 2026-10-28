import AppKit
import CmuxHomeCore
import CmuxNextHibernation
import CmuxNextHomeEngine
import CmuxNextPages
import CmuxNextSettings
import CmuxNextHome
import CmuxNextWakeups

extension InternalPageID {
    /// The docked Home's tab (`HomeDock.page`): the Messages or Channels view.
    static let homeDock = InternalPageID(rawValue: HomeDock.page)
}

/// The docked Home's tab provider (cx-ebm.59.5): one `HomeDockView` per store tab. The view a new
/// tab opens with is the Messages view (Lawrence 2026-10-14: the iMessage Chief by default); the
/// sidebar marks its Home or Channels entry by the view its window shows (`HomeService.dockModes`, cx-frn2y).
@MainActor
final class HomeDockTab: InternalPageProvider {
    private weak var services: AppServices?
    private var views: [String: HomeDockView] = [:]
    /// Each dock view's follow of `home.channelsEnabled` (``HomeDock/followChannelsSetting(_:work:shown:)``), by key.
    private var channelsFollows: [String: ServiceObservation<Bool>] = [:]
    /// Bumped when a dock's view is made or goes: `views` is plain storage, so a reader of ``messagesViews`` hears it.
    private let installs = PageInstallCounter()
    /// The Messages list width every docked Home shares (`HomeSidebarWidth` keeps one per key).
    static let widthKey = "home-dock"
    /// The page command the host asks the Channels page for its selection with (hq-ec's page).
    static let selectionCommand = "home.currentSelection"

    init(services: AppServices) { self.services = services }

    var page: InternalPageID { .homeDock }
    var title: String { HomeStrings.title }
    var symbol: String { "house" }

    /// Work for store tabs whose view is not made yet (an action right after launch), by tab id.
    private var pending: [String: [@MainActor (HomeDockView) -> Void]] = [:]

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services else { return NSView() }
        let view = HomeDockView(services: services, mode: .messages)
        view.channelsSelection = { await Self.askSelection($0) }
        channelsFollows[key] = HomeDock.followChannelsSetting(view, work: services.mainWork) { [weak services] in services?.home.dockModes[key] = $0 }
        views[key] = view
        installs.bump()
        for tab in pending.keys where services.pages.storeKey(of: tab) == key {
            let work = pending.removeValue(forKey: tab) ?? []
            // After this view is in its window, so a sheet has a window to show on.
            view.whenInWindow { for body in work { body(view) } }
        }
        return view
    }

    func tabClosed(_ key: String) {
        views.removeValue(forKey: key)?.close()
        saved[key] = nil
        channelsFollows.removeValue(forKey: key)?.cancel()
        installs.bump()
        services?.home.dockModes[key] = nil // this dock shows nothing now
    }

    // MARK: Discard (`memoryDiscardInternalPages`)

    /// What a discarded dock showed: its view and its Messages page's state.
    struct SavedView: Equatable {
        var mode: HomeDockMode
        var messages: TopHomePageView.ViewState?
    }

    /// What each tab whose view was discarded showed, given to its next view.
    private var saved: [String: SavedView] = [:]

    /// Ten minutes hidden, as a Home tab (``HomePageTab``).
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// A dock stays while its Channels page holds unsent composer input (or anything else that keeps
    /// a page, ``HomeChannelsPageTab/keepReasons(of:)``): that input lives only in the page
    /// (Chrome's `kFormInteractions`). Its Messages view's state is saved and restored instead.
    func keepReasons(for key: String) -> [CannotDiscardReason] {
        HomeChannelsPageTab.keepReasons(of: views[key]?.channels)
    }

    /// The tab stays: its view and Messages state wait for its next view.
    func viewDiscarded(_ key: String) {
        guard let view = views.removeValue(forKey: key) else { return }
        saved[key] = SavedView(mode: view.mode, messages: view.messages?.viewState)
        channelsFollows.removeValue(forKey: key)?.cancel()
        view.close()
        installs.bump()
        services?.home.dockModes[key] = nil // its next view opens on Messages
    }

    /// The Messages page restores its own state, list scroll included (`TopHomePageView.ViewState`),
    /// and the Channels view comes back without taking the keyboard.
    func restoreViewState(_ state: ContentViewState, for key: String, content: NSView) {
        guard let view = content as? HomeDockView, let state = saved.removeValue(forKey: key) else { return }
        if let messages = state.messages { view.messages?.restore(messages) }
        view.restore(state.mode)
    }

    /// Runs `body` on store tab `tabID`'s view now, or once the tab first shows.
    func whenShown(_ tabID: String, services: AppServices, _ body: @escaping @MainActor (HomeDockView) -> Void) {
        if let key = services.pages.storeKey(of: tabID), let view = views[key] { return view.whenInWindow { body(view) } }
        pending[tabID, default: []].append(body)
    }

    /// The Messages view of each docked Home that shows it, by provider key; observed (a view made or gone, a
    /// switch). A dock on Channels shows no conversation, so it has none here.
    var messagesViews: [(key: String, view: TopHomePageView)] {
        _ = installs.revision
        return views.compactMap { key, view in
            guard view.mode == .messages, let messages = view.messages else { return nil }
            return (key, messages)
        }
    }

    // MARK: One Home per window (multiwindow.md; audit-findings-1 C: every window has its Home)

    /// The provider key of window `windowID`'s own Home: the same content model as the home workspace's
    /// dock (HomeService), its own view state. A window whose sidebar asks for Home while another window
    /// lists the home workspace shows this one as its `.home` top page; nothing moves between windows.
    static func windowKey(_ windowID: String) -> String { "home-window:\(windowID)" }

    /// Window `windowID`'s own Home view, made on first use (nil once the app's services are gone).
    func windowView(for windowID: String, in window: WindowController?) -> HomeDockView? {
        let key = Self.windowKey(windowID)
        if views[key] == nil { _ = makeView(for: key, in: window) }
        return views[key]
    }

    /// The Home view window `windowID` shows as its top page, if it shows one.
    static func windowView(_ services: AppServices, windowID: String) -> HomeDockView? {
        (services.pages.provider(.homeDock) as? HomeDockTab)?.views[windowKey(windowID)]
    }

    /// The Home view of the run's window (`WindowManager.active`), in the live tree: that window's own Home page
    /// when it shows one, else the home workspace's dock (nil while it is discarded). One Home per window
    /// (multiwindow.md): an action from window 2 acts on window 2's Home, never on the one window 1 shows.
    static func view(_ services: AppServices) -> HomeDockView? {
        guard let found = dockTab(services, in: services.windows.active) else { return nil }
        return found.provider.views[found.key]
    }

    /// The conversation the run's window's Home shows, live or discarded
    /// (`memoryDiscardInternalPages`: the tab still stands for what its view showed), so an action
    /// needs no live view. Nil before that Home first shows.
    static func shownConversation(_ services: AppServices) -> ConversationID? {
        guard let found = dockTab(services, in: services.windows.active) else { return nil }
        if let view = found.provider.views[found.key] { return view.messages?.shown }
        return found.provider.saved[found.key]?.messages?.shown
    }

    /// Whether the Home window `windowID` shows (its own page when `page` is Home, else the home workspace's
    /// dock) shows Channels: the window's sidebar marks its Channels entry by it.
    static func showsChannels(_ services: AppServices, windowID: String, page: TopPageRoute?) -> Bool {
        // Only a window that shows Home marks Channels (its own page, or the home workspace it lists).
        guard page == .home || services.windows.controller(for: windowID)?.state.workspaceID == services.home.dockedHomeID,
              let key = dockKey(services, windowID: windowID, page: page) else { return false }
        return services.home.dockModes[key] == .channels
    }

    /// The provider key of the Home window `windowID` shows: its own when `page` is Home (docked Home), else the
    /// home workspace's dock tab.
    /// A window that does not list the home workspace has its own Home, also while it shows a workspace: a Home
    /// action from it (send, leave, toggle Channels) acts on its own Home, never on another window's dock.
    static func dockKey(_ services: AppServices, windowID: String?, page: TopPageRoute?) -> String? {
        guard !services.home.dock.isClassic else { return nil }
        if let windowID, page == .home { return windowKey(windowID) }
        guard let home = services.home.homeWorkspace else { return nil }
        if let windowID, let owner = services.windows.registry.value.owner(of: home.id), owner != windowID { return windowKey(windowID) }
        guard let tab = HomeDock.pageTab(in: home)?.tab else { return nil }
        return services.pages.storeKey(of: tab.id) ?? tab.id
    }

    /// The provider and the key of the Home `window` shows (``dockKey(_:windowID:page:)``).
    private static func dockTab(_ services: AppServices, in window: WindowController?) -> (provider: HomeDockTab, key: String)? {
        guard let provider = services.pages.provider(.homeDock) as? HomeDockTab,
              let key = dockKey(services, windowID: window?.state.id, page: window?.state.page) else { return nil }
        return (provider, key)
    }

    /// The page command that moves the Channels list (`home.moveConversation`, hostMove.ts).
    static let moveCommand = "home.moveConversation"

    /// Asks the Channels page to open the conversation `offset` rows away in its list (its own
    /// Option-Up/Down). False when nothing opened: an empty list, an older page (unknown_op), or
    /// no answer within a second.
    static func moveConversation(_ page: PageWebView, by offset: Int) async -> Bool {
        let router = page.router
        let answer = await PageAnswerDeadline(.seconds(1)).answer {
            try await router.callPage(moveCommand, params: .object(["delta": .number(Double(offset))]))
        }
        return answer?.objectValue?["moved"]?.boolValue == true
    }

    /// The Channels page's selection: the page op `home.currentSelection` over the host-to-page
    /// call path (`PageRouter.callPage`, hq-ec's page), `{conversation, message?}` or null. Nil
    /// when the page has none, is older or not connected yet (unknown_op), is gone, or does not
    /// answer within a second: a page that hangs never holds the switch.
    static func askSelection(_ page: PageWebView) async -> HomeDockView.Selection? {
        let router = page.router
        let answer = await PageAnswerDeadline(.seconds(1)).answer { try await router.callPage(selectionCommand, params: .object([:])) }
        guard let fields = answer?.objectValue, let conversation = fields["conversation"]?.stringValue,
              HomeDockSelection.isLinkID(conversation) else { return nil }
        let message = fields["message"]?.stringValue.flatMap { HomeDockSelection.isLinkID($0) ? $0 : nil }
        return HomeDockView.Selection(conversation: conversation, message: message)
    }
}

/// `cmux.host.home.switchView {view: "messages" | "channels", conversation?, message?}` of the
/// docked Home's Channels page (COORD.md contract): the dock shows `view` (the sidebar's Home or
/// Channels entry; channels only while Channels is enabled), with the given selection, else the
/// current one handed over. Answers `{view}`. Bound to one dock view, so a Channels page outside the
/// dock (a plain tab, a browser) has no such verb (unknown_op).
@MainActor
final class HomeSwitchPageRoute: PageProvider {
    nonisolated static let prefix = "cmux.host.home."
    private weak var dock: HomeDockView?

    init(dock: HomeDockView) { self.dock = dock }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard op == Self.prefix + "switchView", let dock else { throw PageError.unknownOp(op) }
        let fields = params.objectValue ?? [:]
        guard let view = fields["view"]?.stringValue.flatMap(HomeDockView.Mode.init(rawValue:)) else {
            throw PageError(code: "cmux.home.invalid_view", message: "view must be messages or channels", retryable: false)
        }
        guard view.isEnabled else { throw PageError(code: "cmux.home.channels_off", message: HomeDockMode.channelsOffMessage, retryable: false) }
        let conversation = fields["conversation"]?.stringValue
        let message = fields["message"]?.stringValue
        if let conversation, !HomeDockSelection.isLinkID(conversation) || !(message.map(HomeDockSelection.isLinkID) ?? true) {
            throw PageError(code: "cmux.home.invalid_selection", message: "not a conversation or message id", retryable: false)
        }
        dock.switchTo(view, selection: conversation.map { HomeDockView.Selection(conversation: $0, message: message) })
        await dock.settled()
        return .object(["view": .string(dock.mode.rawValue)])
    }
}
