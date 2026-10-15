import AppKit
import CmuxHomeCore
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextPages

/// The docked Home's tab content (cx-ebm.59.5; Lawrence 2026-10-14: "bring imessage chief back by
/// default instead of slack", "easy way to open slack ... we want to iterate on both UIs at the same
/// time"). One native header with the "Messages | Channels" switch at its top left, over one of two
/// views of the same Home data: Messages, the native MessagesLab list and transcript
/// (`TopHomePageView`, the same view classic Home shows), or Channels, hq-ec's `home-channels`
/// page. The page draws no switch of its own. Each view is made on its first show and kept, so a
/// switch back keeps its scroll, draft and selection. The switch hands the selection over as a
/// permalink: Messages -> Channels opens `#/conversation/<id>[/message/<id>]` in the page;
/// Channels -> Messages asks the page for its selection (`home.currentSelection`).
@MainActor
final class HomeDockView: NSView {
    /// The two views of the docked Home (`home.switchView`).
    enum Mode: String, CaseIterable, Sendable {
        case messages, channels

        var other: Mode { self == .messages ? .channels : .messages }
    }

    /// The selection a switch carries over (the permalink's parts).
    struct Selection: Equatable, Sendable {
        var conversation: String
        var message: String?

        /// The page route of the selection (hq-ec's hash contract, COORD.md).
        var route: String { "/conversation/\(conversation)" + (message.map { "/message/\($0)" } ?? "") }
    }

    private weak var services: AppServices?
    let header = NSView()
    let control: HomeDockSwitchControl
    private let content = NSView()
    private(set) var mode: Mode
    private(set) var messages: TopHomePageView?
    private(set) var channels: PageWebView?
    /// Asks the Channels page for its selection (`home.currentSelection`); nil when it has none
    /// or does not answer. Set by the provider (the page's reply path).
    var channelsSelection: (@MainActor (PageWebView) async -> Selection?)?
    /// A switch in flight: a second one waits for it, so two quick clicks end on the last choice.
    private var switching: Task<Void, Never>?
    static let headerHeight: CGFloat = 30

    init(services: AppServices, mode: Mode) {
        self.services = services
        self.mode = mode
        control = HomeDockSwitchControl(labels: [HomeDockStrings.messages, HomeDockStrings.channels], trackingMode: .selectOne,
                                     target: nil, action: nil)
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.homeDock")
        control.segmentStyle = .rounded
        control.controlSize = .small
        control.toolTip = HomeDockStrings.switchHelp
        control.setAccessibilityIdentifier("cmux.homeDock.switch")
        control.target = self
        control.action = #selector(controlChanged)
        header.addSubview(control)
        addSubview(header)
        addSubview(content)
        show(mode)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Work that needs this view in a window (a sheet, the keyboard).
    private var windowWaiters: [@MainActor () -> Void] = []

    /// Runs `body` now when this view is in a window, else when it moves into one.
    func whenInWindow(_ body: @escaping @MainActor () -> Void) {
        if window != nil { body() } else { windowWaiters.append(body) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !windowWaiters.isEmpty else { return }
        let waiters = windowWaiters
        windowWaiters = []
        for body in waiters { body() }
    }

    override func layout() {
        super.layout()
        let height = Self.headerHeight
        header.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        control.sizeToFit()
        // Top left, centered in the header's height.
        control.setFrameOrigin(NSPoint(x: 8, y: ((height - control.frame.height) / 2).rounded()))
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - height))
    }

    @objc private func controlChanged() {
        // Not compared with `mode`: a switch in flight has not changed it yet, and the last click wins.
        guard let picked = Mode.allCases[safe: control.selectedSegment] else { return }
        switchTo(picked)
    }

    /// Switches to `target` (the other view when nil) with `selection`, else the current selection
    /// handed over. Two quick switches run in order, so the last one wins.
    func switchTo(_ target: Mode?, selection given: Selection? = nil) {
        let previous = switching
        // task-owner: one switch; a page answer is bounded by `channelsSelection`'s deadline.
        switching = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let target = target ?? mode.other
            guard target != mode else {
                if let given { open(given) }
                return syncControl()
            }
            var selection = given
            if selection == nil { selection = await currentSelection() }
            show(target)
            if let selection { open(selection) }
            focusPrimaryInput()
        }
    }

    /// Waits for the switch in flight, if any (debug and tests).
    func settled() async { await switching?.value }

    /// The shown view's selection: the native view's conversation (and its open thread's root
    /// message), or the page's answer.
    func currentSelection() async -> Selection? {
        switch mode {
        case .messages:
            guard let shown = messages?.shown else { return nil }
            // A Cloud conversation's message link has no resolver in the page yet (hq-ec G4): the conversation only.
            let cloud = services?.home.isCloudConversation(shown) ?? false
            let thread = cloud ? nil : messages?.host.flatMap { HomePageTab.transcript(in: $0) }?.openThreadRoot
            return Selection(conversation: shown.rawValue, message: thread)
        case .channels:
            guard let channels, let ask = channelsSelection else { return nil }
            return await ask(channels)
        }
    }

    /// Shows `selection` in the current view: the native list selects the conversation (the
    /// native view has no message highlight yet: MessagesLab C4), the page follows its hash.
    func open(_ selection: Selection) {
        switch mode {
        case .messages:
            messages?.show(ConversationID(selection.conversation))
        case .channels:
            open(route: selection.route)
        }
    }

    /// The page at `route` (Channels only), "#/" first when already there (hq-ec's contract).
    func open(route: String) {
        guard let channels else { return }
        if channels.route == "#" + route { channels.open(route: "/") }
        channels.open(route: route)
    }

    /// The shown view's primary input takes the keyboard (the message box, or the page).
    func focusPrimaryInput() {
        switch mode {
        case .messages: messages?.focusPrimaryInput()
        case .channels:
            guard let channels else { return }
            if channels.window != nil { channels.focusPage() } else { channels.whenPainted { [weak channels] in channels?.focusPage() } }
        }
    }

    private func show(_ target: Mode) {
        mode = target
        let view: NSView? = switch target {
        case .messages: messages ?? makeMessages()
        case .channels: channels ?? makeChannels()
        }
        for subview in content.subviews where subview !== view { subview.isHidden = true }
        if let view {
            view.isHidden = false
            if view.superview !== content {
                view.frame = content.bounds
                view.autoresizingMask = [.width, .height]
                content.addSubview(view)
            }
        }
        syncControl()
    }

    private func syncControl() {
        control.selectedSegment = Mode.allCases.firstIndex(of: mode) ?? 0
    }

    private func makeMessages() -> TopHomePageView? {
        guard let services else { return nil }
        let view = TopHomePageView(services: services, windowKey: { HomeDockTab.widthKey })
        messages = view
        return view
    }

    private func makeChannels() -> PageWebView? {
        guard let services, let page = PageFactory(services: services).homeChannelsWebPage(dock: self) else { return nil }
        // A web link the person clicks opens on the Home workspace's right side (cx-ebm.59.6).
        page.onOpenExternal = { [weak services] in services?.home.dock.openLink($0, on: services?.daemon.connection) }
        channels = page
        return page
    }

    /// The tab closed: the page's document ends.
    func close() {
        switching?.cancel()
        channels?.close()
    }
}

/// The header switch: a click on it works in a window that is not key (no first click lost to
/// window activation), like a toolbar control.
final class HomeDockSwitchControl: NSSegmentedControl {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

nonisolated enum HomeDockStrings {
    static var messages: String {
        String(localized: "homeDock.view.messages", defaultValue: "Messages", table: "Handlers", bundle: .module)
    }

    static var channels: String {
        String(localized: "homeDock.view.channels", defaultValue: "Channels", table: "Handlers", bundle: .module)
    }

    static var invalidView: String {
        String(localized: "homeDock.switch.invalidView", defaultValue: "Home has two views: messages and channels.", table: "Handlers", bundle: .module)
    }

    static var classicHasOneView: String {
        String(localized: "homeDock.switch.classic", defaultValue: "Classic Home has only the Messages view.", table: "Handlers", bundle: .module)
    }

    static var switchHelp: String {
        String(localized: "homeDock.switch.help", defaultValue: "Show Home as Messages or as Channels", table: "Handlers", bundle: .module)
    }
}
