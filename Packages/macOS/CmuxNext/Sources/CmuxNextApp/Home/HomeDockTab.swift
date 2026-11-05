import AppKit
import CmuxNextHomeEngine
import CmuxNextPages
import CmuxNextSettings
import CmuxNextHome

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
        HomeDock.followChannelsSetting(view) { [weak services] in services?.home.dockMode = $0 }
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
        services?.home.dockMode = .messages // no dock view shows Channels now
    }

    /// Runs `body` on store tab `tabID`'s view now, or once the tab first shows.
    func whenShown(_ tabID: String, services: AppServices, _ body: @escaping @MainActor (HomeDockView) -> Void) {
        if let key = services.pages.storeKey(of: tabID), let view = views[key] { return view.whenInWindow { body(view) } }
        pending[tabID, default: []].append(body)
    }

    /// The active window's docked Home view in the live tree (cmux#27880: each window has its own),
    /// once its tab has shown.
    static func view(_ services: AppServices) -> HomeDockView? {
        let home = services.windows.active.map { services.windowHomes.home(in: $0.state.id) } ?? services.home.homeWorkspace
        guard let tab = home.flatMap(HomeDock.pageTab(in:))?.tab,
              let provider = services.pages.provider(.homeDock) as? HomeDockTab else { return nil }
        let key = services.pages.storeKey(of: tab.id) ?? tab.id
        return provider.views[key]
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
