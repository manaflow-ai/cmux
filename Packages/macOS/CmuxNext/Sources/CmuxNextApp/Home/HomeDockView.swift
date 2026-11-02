import AppKit
import CmuxHomeCore
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextPages

/// The docked Home's two views over `HomeDockSwitchView` (cx-ebm.59.5, cx-frn2y): Messages, the native MessagesLab
/// list and transcript (`TopHomePageView`, as classic Home; the sidebar's Home entry), and Channels, hq-ec's `home-channels`
/// page (the sidebar's Channels entry). Messages -> Channels opens `#/conversation/<id>[/message/<id>]` in the page;
/// Channels -> Messages asks the page for its selection (`home.currentSelection`).
final class HomeDockView: HomeDockSwitchView, PageWebViewContainer {
    typealias Mode = HomeDockMode
    typealias Selection = HomeDockSelection

    private weak var services: AppServices?
    private(set) var messages: TopHomePageView?
    private(set) var channels: PageWebView?
    /// The page the focus model gives the keyboard to (``PageWebView/shown(in:)``): Channels while it shows.
    var shownPageView: PageWebView? { mode == .channels ? channels : nil }
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
            messages = TopHomePageView(services: services, windowKey: { HomeDockTab.widthKey })
            return messages
        case .channels:
            guard let page = PageFactory(services: services).homeChannelsWebPage(dock: self) else { return nil }
            // A web link the person clicks opens on the Home workspace's right side (cx-ebm.59.6).
            page.onOpenExternal = { [weak services] in services?.home.dock.openLink($0, on: services?.daemon.connection) }
            channels = page
            return page
        }
    }

    /// The native view's conversation (and its open thread view's branch message, else root), or the page's answer.
    override func selection(in mode: Mode) async -> Selection? {
        switch mode {
        case .messages:
            guard let shown = messages?.shown else { return nil }
            // A Cloud conversation keeps its message too: with no owner resolver, the page pages its own
            // timeline to the message and opens its thread (store.ts openKnown), as the native view does.
            let thread = messages?.host.flatMap { HomePageTab.transcript(in: $0) }?.openThreadMessage
            return Selection(conversation: shown.rawValue, message: thread)
        case .channels:
            guard let channels, let ask = channelsSelection else { return nil }
            return await ask(channels)
        }
    }

    /// The native list selects the conversation and opens the message's thread branch; the page follows its hash.
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
    }
}
