import AppKit
import CmuxHomeCore
import CmuxNextHome
import CmuxNextHomeModel
import CmuxNextHomeEngine
import CmuxNextLayout
import CmuxNextPages

/// The docked Home's two views over `HomeDockSwitchView` (cx-ebm.59.5, cx-frn2y): Messages, the React `home-messages`
/// page (``HomeMessagesPage``; the sidebar's Home entry), and Channels, hq-ec's `home-channels` page (the sidebar's
/// Channels entry). A switch asks the shown page for its selection (`home.currentSelection`) and opens it in the other:
/// Channels by `#/conversation/<id>[/message/<id>]`, Messages by `home.messages.show`.
final class HomeDockView: HomeDockSwitchView, PageWebViewContainer {
    typealias Mode = HomeDockMode
    typealias Selection = HomeDockSelection

    private weak var services: AppServices?
    private(set) var messages: HomeMessagesPage?
    private(set) var channels: PageWebView?
    /// The page the focus model gives the keyboard to (``PageWebView/shown(in:)``): the shown view's.
    var shownPageView: PageWebView? { mode == .channels ? channels : messages?.page }
    /// Asks the Channels page for its selection (`home.currentSelection`); nil when none or no answer (the page's reply path).
    var channelsSelection: (@MainActor (PageWebView) async -> Selection?)?

    init(services: AppServices, mode: Mode) {
        self.services = services
        super.init(mode: mode)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func makeContent(for mode: Mode) -> NSView? {
        guard let services else { return nil }
        switch mode {
        case .messages:
            guard let view = HomeMessagesPage.make(services: services, dock: self) else { return nil }
            messages = view
            view.host.seeThrough.onHeaderHeight = { [weak self] in self.map { HomeMessagesSeeThrough.relayout(from: $0) { $0 is ChiefPanelView } } }
            return view
        case .channels:
            guard let page = PageFactory(services: services).homeChannelsWebPage(dock: self) else { return nil }
            // A web link the person clicks opens on the Home workspace's right side (cx-ebm.59.6).
            page.onOpenExternal = { [weak services] in services?.home.dock.openLink($0, on: services?.daemon.connection) }
            channels = page
            return page
        }
    }

    /// The shown page's answer (`home.currentSelection`).
    override func selection(in mode: Mode) async -> Selection? {
        switch mode {
        case .messages:
            guard let messages else { return nil }
            if let answer = await messages.selection() { return answer }
            return messages.shown.map { Selection(conversation: $0.rawValue) }
        case .channels:
            guard let channels, let ask = channelsSelection else { return nil }
            return await ask(channels)
        }
    }

    /// The Messages page opens the conversation (and the message); the Channels page follows its hash.
    override func open(_ selection: Selection, in mode: Mode) {
        switch mode {
        case .messages: messages?.show(selection)
        case .channels: open(route: selection.route)
        }
    }

    /// The page at `route` (Channels only), "#/" first when already there (hq-ec's contract).
    func open(route: String) {
        guard let channels else { return }
        if channels.route == "#" + route { channels.open(route: "/") }
        channels.open(route: route)
    }

    override func focusContent(_ mode: Mode) {
        switch mode {
        case .messages: messages?.focusPrimaryInput()
        case .channels:
            guard let channels else { return }
            if channels.window != nil { channels.focusPage() } else { channels.whenPainted { [weak channels] in channels?.focusPage() } }
        }
    }

    /// The tab closed: the page's document ends.
    override func close() {
        super.close()
        channels?.close()
        messages?.close()
    }
}
/// The Messages page's shown conversation has a running Chief reply (the store's live run); the see-through Chief
/// clears the Messages page and takes its header height (``HomeMessagesSeeThrough``), as base's HomeDockView did.
extension HomeDockView: ChiefPanelContent {
    var chiefIsAnswering: Bool { mode == .messages && messages?.shown.flatMap { services?.home.homeStore.liveRun(in: $0) } != nil }
    var chiefShowsThrough: Bool { get { messages?.host.seeThrough.showsThrough == true } set { messages?.host.seeThrough.showsThrough = newValue } }
    var chiefHeaderHeight: CGFloat { messages.map { $0.host.seeThrough.headerHeight(zoom: $0.page.pageZoom) } ?? 0 }
}
