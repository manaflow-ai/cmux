import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextHomeModel
import CmuxNextLayout
import CmuxNextPages
import CmuxNextSettings

/// A conversation tab's content (`conversation-tabs-v1`) and the Chief panel's: the React Messages
/// page for one conversation (`cmux.home-messages` at `#/conversation/<id>`, no list), over the
/// local daemon's Home data like the docked page. The app adds what only it knows: the Chief's
/// settings popover under the page's name pill and Stop (``HomeChiefSurface``), whether the Chief
/// answers (the panel's Esc), and the keyboard landing in the page's message box.
@MainActor
final class HomeConversationPage: NSView {
    let conversation: ConversationID
    let page: PageWebView
    let host: HomeMessagesHostProvider
    let chief: HomeChiefSurface
    private weak var services: AppServices?
    /// How long the page call that gives the message box the keyboard waits for the page.
    static let answerDeadline: Duration = .seconds(5)

    init(services: AppServices, conversation: ConversationID, page: PageWebView, host: HomeMessagesHostProvider) {
        self.services = services
        self.conversation = conversation
        self.page = page
        self.host = host
        chief = HomeChiefSurface(services: services, conversation: conversation, owner: page)
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.homeConversation")
        wantsLayer = true
        addSubview(page)
        host.toastAvoidance.attach(self, page: page)
        host.chiefShown = { [weak self] id in id == conversation ? self?.chief : nil }
        host.follow(chief)
        host.seeThrough.onHeaderHeight = { [weak self] in self.map { HomeMessagesSeeThrough.relayout(from: $0) { $0 is ChiefPanelView } } }
        // A launch holds a Home still being made until its page paints (WorkspaceContentController).
        let reveal = services.launchReveal
        page.whenPainted { reveal.markReady(.home); DebugTimings.markLaunch("home.first_page") }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The page for conversation `id`; nil when the page bundle is missing.
    static func make(services: AppServices, conversation: String) -> HomeConversationPage? {
        let id = ConversationID(conversation)
        guard let made = PageFactory(services: services).homeMessagesWebPage(conversation: id) else { return nil }
        // A web link the person clicks opens on the Home workspace's right side, as in the docked page.
        made.page.onOpenExternal = { [weak services] in services?.home.dock.openLink($0, on: services?.daemon.connection) }
        return HomeConversationPage(services: services, conversation: id, page: made.page, host: made.host)
    }

    override var isFlipped: Bool { true }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // The pane paints under Home (`Palette.paneFill`). The live-code measures recolour this line.
        layer?.backgroundColor = nil
    }

    override func layout() {
        super.layout()
        page.frame = bounds
        host.toastAvoidance.moved()
    }

    /// The popover is a child panel of the window, not a subview: the page leaving its window (a tab
    /// or workspace switch, Cmd-W) or hiding closes it, so it never stays over the next pane.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow !== window { chief.close() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        chief.openPendingSettings()
    }

    override func viewDidHide() {
        super.viewDidHide()
        chief.close()
    }

    /// The view that takes the keyboard when the tab's pane is focused: the page's own web content.
    var focusTarget: NSView { page.focusView }

    /// The pane got the keyboard: the page takes it, and its message box gets it.
    func focusPrimaryInput() {
        let focus = { [weak self] in
            guard let self else { return }
            page.focusPage()
            let router = page.router
            // task-owner: one page call; ends with its answer or the deadline
            // main-hop-allow: already on main (a focus request); the task only awaits the page's answer
            Task { @MainActor in
                _ = await PageAnswerDeadline(Self.answerDeadline).answer { try await router.callPage("home.messages.focusComposer", params: .object([:])) }
            }
        }
        if page.hasPainted { focus() } else { page.whenPainted(focus) }
    }

    /// The tab closed: the page's document ends once it has handed the app what it held alone
    /// (``HomeComposerHandoff/settle()``: the pause's drafts, an unanswered send or staged file).
    func close() {
        chief.close()
        host.dictation.close()
        let page = page, handoff = composerHandoff
        guard page.hasPainted else { return page.close() }
        // task-owner: keeps the closed page until its settle answers (bounded by settleDeadline), then ends it
        Task { await handoff.settle(); page.close() }
    }
}

/// Up and Down while the tab has the keyboard outside the page step its box's history; toasts rest
/// above the page's compose bar (``HomePageToastAvoidance``).
extension HomeConversationPage: PrimaryInputTarget, CmuxToastAvoiding {
    var primaryInputView: NSView? { nil }
    var acceptsRedirectedTyping: Bool { true }
    func primaryInputShouldTakeKeyboard(from responder: NSResponder?) -> Bool { false }
    func routesToPrimaryInput(_ event: NSEvent) -> Bool { HomeComposerHandoff.historyArrow(event, outside: page) != nil }
    var toastAvoidanceRect: NSRect { host.toastAvoidance.rect(in: self) }
    func beginTyping(with event: NSEvent) { recallHistory(event, page: page) }
}

extension HomeConversationPage: HomeComposerHosting {
    var composerHandoff: HomeComposerHandoff { HomeComposerHandoff(page: page, files: host.composerFiles) }
}

extension HomeConversationPage: HomeChiefShowing {
    var shownChief: HomeChiefSurface? { chief.showsChiefOnScreen ? chief : nil }
}

/// The see-through Chief: the page clears its background and reports its header (``HomeMessagesSeeThrough``).
extension HomeConversationPage: ChiefPanelContent {
    var chiefIsAnswering: Bool { chief.isWorking }
    var chiefShowsThrough: Bool { get { host.seeThrough.showsThrough } set { host.seeThrough.showsThrough = newValue } }
    var chiefHeaderHeight: CGFloat { host.seeThrough.headerHeight(zoom: page.pageZoom) }
}
