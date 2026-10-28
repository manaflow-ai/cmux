import AppKit
import CmuxHomeCore
import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextPages

/// The docked Home's two views over `HomeDockSwitchView` (cx-ebm.59.5, cx-frn2y): Messages, the native
/// MessagesLab list and transcript (`TopHomePageView`, the same view classic Home shows; the sidebar's
/// Home entry), and Channels, hq-ec's `home-channels` page (the sidebar's Channels entry). Messages -> Channels
/// opens `#/conversation/<id>[/message/<id>]` in the page; Channels -> Messages asks the page for
/// its selection (`home.currentSelection`).
final class HomeDockView: HomeDockSwitchView {
    typealias Mode = HomeDockMode
    typealias Selection = HomeDockSelection

    private weak var services: AppServices?
    private(set) var messages: TopHomePageView?
    private(set) var channels: PageWebView?
    /// Asks the Channels page for its selection (`home.currentSelection`); nil when it has none
    /// or does not answer. Set by the provider (the page's reply path).
    var channelsSelection: (@MainActor (PageWebView) async -> Selection?)?

    /// - Parameters:
    ///   - planner: The sidebar section planner that lets the hidden view go (the app's, nil while
    ///     `memoryDiscardSidebarSections` is off).
    init(services: AppServices, mode: Mode, planner: (any SidebarSectionPlanner)?) {
        self.services = services
        super.init(mode: mode, planner: planner)
    }

    convenience init(services: AppServices, mode: Mode) {
        self.init(services: services, mode: mode, planner: services.sidebarSectionDiscards)
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

    /// Messages keeps its list's search and scroll with its conversation (``TopHomePageView``'s own record, as
    /// classic Home's discard keeps them); Channels keeps the page's route with the page's selection.
    override func saveViewState(in mode: Mode) async -> HomeDockRecord? {
        let shown = await selection(in: mode)
        switch mode {
        case .messages:
            guard let messages else { return nil }
            var state = PageViewState()
            messages.saveViewState(messages, into: &state)
            return HomeDockRecord(selection: shown,
                                  view: SidebarSectionState(scroll: state.scroll[TopHomePageView.listScrollKey], query: state.search))
        case .channels:
            guard let channels else { return nil }
            return HomeDockRecord(selection: shown, route: channels.route)
        }
    }

    /// Messages takes its search, conversation and list scroll back (the scroll once its rows are in) and opens the
    /// thread's message; Channels opens its route.
    override func restoreViewState(_ record: HomeDockRecord, in mode: Mode) {
        switch mode {
        case .messages:
            guard let messages else { return }
            let scroll = record.view.scroll.map { [TopHomePageView.listScrollKey: $0] } ?? [:]
            messages.restoreViewState(PageViewState(scroll: scroll, selection: record.selection?.conversation, search: record.view.query),
                                      in: messages)
            if let selection = record.selection, selection.message != nil { messages.show(selection) }
        case .channels:
            // The page's route is its hash ("#/conversation/c1"); open(route:) takes it without the "#".
            let route = record.route.map { hash in String(hash.drop { $0 == "#" }) } ?? ""
            if !route.isEmpty {
                open(route: route)
            } else if let selection = record.selection {
                open(route: selection.route)
            }
        }
    }

    /// An unsent New Message in Messages (which no store keeps); in Channels, what the page or the host holds on it
    /// (its composer's unsent text, `cmux.page.keepAlive` `draft`; a sheet or a menu it opened).
    override func holdsUnsavedInput(in mode: Mode) -> Bool {
        switch mode {
        case .messages: messages.map { $0.holdsUnsavedInput($0) } ?? false
        case .channels: channels?.keepReasons.current.contains { $0.blocksDiscard } ?? false
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

    /// The planner let the hidden view go (feature `memoryDiscardSidebarSections`): Channels' document ends.
    override func releaseContent(for mode: Mode) {
        switch mode {
        case .messages: messages = nil
        case .channels:
            channels?.close()
            channels = nil
        }
    }

    /// The tab closed: the page's document ends.
    override func close() {
        super.close()
        channels?.close()
    }
}
