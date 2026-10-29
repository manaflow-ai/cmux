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
/// sidebar marks its Home or Channels entry by the shown view (`HomeService.dockMode`, cx-frn2y).
@MainActor
final class HomeDockTab: InternalPageProvider {
    private weak var services: AppServices?
    private var views: [String: HomeDockView] = [:]
    /// Each dock view's follow of `home.channelsEnabled` (``HomeDock/followChannelsSetting(_:work:shown:)``), by key.
    private var channelsFollows: [String: ServiceObservation<Bool>] = [:]
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
        channelsFollows[key] = HomeDock.followChannelsSetting(view, work: services.mainWork) { [weak services] in services?.home.dockMode = $0 }
        views[key] = view
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
        services?.home.dockMode = .messages // no dock view shows Channels now
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
        if view.mode == .channels { services?.home.dockMode = .messages } // its next view opens on Messages
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

    /// The docked Home's view in the live tree, once its tab has shown (nil while it is discarded).
    static func view(_ services: AppServices) -> HomeDockView? {
        guard let found = dockTab(services) else { return nil }
        return found.provider.views[found.key]
    }

    /// The conversation the docked Messages view shows, live or discarded
    /// (`memoryDiscardInternalPages`: the tab still stands for what its view showed), so an action
    /// needs no live view. Nil before the dock first shows.
    static func shownConversation(_ services: AppServices) -> ConversationID? {
        guard let found = dockTab(services) else { return nil }
        if let view = found.provider.views[found.key] { return view.messages?.shown }
        return found.provider.saved[found.key]?.messages?.shown
    }

    /// The docked Home's provider and its tab's provider key.
    private static func dockTab(_ services: AppServices) -> (provider: HomeDockTab, key: String)? {
        guard let tab = services.home.homeWorkspace.flatMap(HomeDock.pageTab(in:))?.tab,
              let provider = services.pages.provider(.homeDock) as? HomeDockTab else { return nil }
        return (provider, services.pages.storeKey(of: tab.id) ?? tab.id)
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
