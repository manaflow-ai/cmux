import AppKit
import CmuxNextHomeEngine
import CmuxNextPages
import CmuxNextSettings
import CmuxNextCompat
import CmuxNextWakeups

extension InternalPageID {
    /// The docked Home's tab (`HomeDock.page`): the switch and the Messages or Channels view.
    static let homeDock = InternalPageID(rawValue: HomeDock.page)
}

/// The docked Home's tab provider (cx-ebm.59.5): one `HomeDockView` per store tab. The view a new
/// tab opens with is the Messages view (Lawrence 2026-10-14: the iMessage Chief by default).
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
        views[key] = view
        for tab in pending.keys where services.pages.storeKey(of: tab) == key {
            let work = pending.removeValue(forKey: tab) ?? []
            // After this view is in its window, so a sheet has a window to show on.
            view.whenInWindow { for body in work { body(view) } }
        }
        return view
    }

    func tabClosed(_ key: String) { views.removeValue(forKey: key)?.close() }

    /// Runs `body` on store tab `tabID`'s view now, or once the tab first shows.
    func whenShown(_ tabID: String, services: AppServices, _ body: @escaping @MainActor (HomeDockView) -> Void) {
        if let key = services.pages.storeKey(of: tabID), let view = views[key] { return view.whenInWindow { body(view) } }
        pending[tabID, default: []].append(body)
    }

    /// The docked Home's view in the live tree, once its tab has shown.
    static func view(_ services: AppServices) -> HomeDockView? {
        guard let tab = services.home.homeWorkspace.flatMap(HomeDock.pageTab(in:))?.tab,
              let provider = services.pages.provider(.homeDock) as? HomeDockTab else { return nil }
        let key = services.pages.storeKey(of: tab.id) ?? tab.id
        return provider.views[key]
    }

    /// The Channels page's selection: the page op `home.currentSelection` over the host-to-page
    /// call path (`PageRouter.callPage`, hq-ec's page), `{conversation, message?}` or null. Nil
    /// when the page has none, is older or not connected yet (unknown_op), is gone, or does not
    /// answer within a second: a page that hangs never holds the switch.
    static func askSelection(_ page: PageWebView) async -> HomeDockView.Selection? {
        let once = HomeDockOnce()
        let deadline = DemandTimer(owner: "HomeDockTab.currentSelection")
        deadline.schedule(after: .seconds(1)) { once.resume(nil) }
        let router = page.router
        // task-owner: one page call; ends with the page's answer or its close (the deadline answers first if it hangs).
        Task { @MainActor in
            once.resume(try? await router.callPage(selectionCommand, params: .object([:])))
        }
        let answer = await once.value()
        deadline.cancel()
        guard let fields = answer?.objectValue, let conversation = fields["conversation"]?.stringValue,
              HomeDockLinkID.isValid(conversation) else { return nil }
        let message = fields["message"]?.stringValue.flatMap { HomeDockLinkID.isValid($0) ? $0 : nil }
        return HomeDockView.Selection(conversation: conversation, message: message)
    }
}

/// The first of the page's answer and the deadline: later ones are dropped.
private nonisolated final class HomeDockOnce: Sendable {
    private struct State {
        var done = false
        var value: CmuxNextSettings.JSONValue?
        var waiter: CheckedContinuation<CmuxNextSettings.JSONValue?, Never>?
    }

    private let state = Mutex(State())

    func resume(_ value: CmuxNextSettings.JSONValue?) {
        let waiter = state.withLock { state -> CheckedContinuation<CmuxNextSettings.JSONValue?, Never>? in
            guard !state.done else { return nil }
            state.done = true
            state.value = value
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: value)
    }

    func value() async -> CmuxNextSettings.JSONValue? {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> (Bool, CmuxNextSettings.JSONValue?) in
                if state.done { return (true, state.value) }
                state.waiter = continuation
                return (false, nil)
            }
            if ready.0 { continuation.resume(returning: ready.1) }
        }
    }
}

/// A conversation or message id from a page or a caller: only the permalink grammar's characters
/// (letters, digits, `_`, `-`; at most 128), so it can only ever name an id in a route.
nonisolated enum HomeDockLinkID {
    static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
            && id.allSatisfy(\.isASCII)
    }
}

/// `cmux.host.home.switchView {view: "messages" | "channels", conversation?, message?}` of the
/// docked Home's Channels page (COORD.md contract): the dock shows `view`, with the given
/// selection, else the current one handed over. Answers `{view}`. Bound to one dock view, so a
/// Channels page outside the dock (a plain tab, a browser) has no such verb (unknown_op).
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
        let conversation = fields["conversation"]?.stringValue
        let message = fields["message"]?.stringValue
        if let conversation, !HomeDockLinkID.isValid(conversation) || !(message.map(HomeDockLinkID.isValid) ?? true) {
            throw PageError(code: "cmux.home.invalid_selection", message: "not a conversation or message id", retryable: false)
        }
        dock.switchTo(view, selection: conversation.map { HomeDockView.Selection(conversation: $0, message: message) })
        await dock.settled()
        return .object(["view": .string(dock.mode.rawValue)])
    }
}
