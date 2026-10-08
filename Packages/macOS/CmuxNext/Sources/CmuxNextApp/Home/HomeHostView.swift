import AppKit
import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextActions
import CmuxNextDesign
import CmuxNextHome
import CmuxNextWakeups

/// A conversation tab's content (`conversation-tabs-v1`, home.md 7): the
/// native AppKit transcript (`HomeNativeTranscriptView`, MessagesLab's code,
/// home-mac.md) over the shared `HomeStore` of the local conversation owner,
/// or why it cannot show (the local daemon does not serve conversations).
@MainActor
final class HomeHostView: NSView {
    private let transcript: HomeNativeTranscriptView
    private let message = NSTextField(labelWithString: "")
    private var availability: Task<Void, Never>?
    /// The Chief's settings, a right sidebar the header's name pill toggles
    /// (Chief conversation only); the transcript narrows while it shows.
    private let sidebar: HomeChiefSidebar
    /// The one owner of the sidebar's motion: `layout()` and every frame of
    /// the slide place the transcript and the sidebar from it.
    private var slide = HomeSidebarSlide()
    /// Frames for the slide; made on the first toggle, idle when settled.
    private var slideClient: FrameClient?
    private var isChief = false
    private var engineWatch: Task<Void, Never>?
    private var toggleObserver: (any NSObjectProtocol)?
    /// `home.toggleChiefSettings` (palette, `cmux action run`, preflight).
    static let toggleSettings = Notification.Name("HomeHostView.toggleChiefSettings")
    private var firstPage: Task<Void, Never>?

    init(services: AppServices, conversation: String) {
        let service = services.home
        let id = ConversationID(conversation)
        transcript = HomeNativeTranscriptView(store: service.homeStore, conversation: id, me: service.homeSource.me.id)
        sidebar = HomeChiefSidebar(muxHome: HomeBrainHost.muxHome(tag: services.environment.tag))
        super.init(frame: .zero)
        sidebar.isHidden = true
        transcript.setNamePillHelp(HomeEngineStrings.pillHelp)
        transcript.onNamePill = { [weak self] in self?.toggleSidebar() }
        let files = HomeChiefFiles(muxHome: HomeBrainHost.muxHome(tag: services.environment.tag))
        // task-owner: one profile read off the main actor; ends when it is shown
        Task { [weak self] in
            let avatar = await Task.detached { files.avatar() }.value
            self?.transcript.avatarText = avatar
        }
        sidebar.onAvatar = { [weak self] text in self?.transcript.avatarText = text }
        sidebar.onShowMemory = { [weak services] in
            _ = services?.registry.perform(ChiefInspectorHandlers.actionID, invocation: ActionInvocation(origin: .user))
        }
        sidebar.onRename = { [weak service] name in
            guard let connection = service?.connection else { return }
            // task-owner: one op; ends with its reply
            Task {
                let key = "home-chief-rename-\(UUID().uuidString.lowercased())"
                _ = try? await CmuxNextDaemon.ConversationClient(connection).op(
                    CmuxNextDaemon.ConversationOpRequest(conversation: conversation, idempotencyKey: key, transaction: nil, op: .setTitle(name)))
            }
        }
        toggleObserver = NotificationCenter.default.addObserver(forName: Self.toggleSettings, object: nil, queue: .main) { [weak self] _ in
            // task-owner: one hop to the main actor for the toggle
            Task { @MainActor in self?.toggleSidebar() }
        }
        let store = service.homeStore
        // task-owner: lives as long as this view; event-driven (Observation):
        // whether this is the Chief conversation, and a refresh of the
        // sidebar's last turn on each new message.
        engineWatch = Task { [weak self] in
            for await (isChief, _, title) in Observations({ () -> (Bool, Int, String) in
                let row = store.rows.first { $0.summary.id == id }
                let chief = row?.summary.participants.contains { $0.agentClass == .chief } ?? false
                return (chief, store.transcriptVersion[id] ?? 0, row?.summary.title ?? "")
            }) {
                guard let self else { return }
                self.isChief = isChief
                sidebar.setName(title)
                if !isChief, slide.isOpen { toggleSidebar() }
                if slide.isOpen { sidebar.refresh() }
            }
        }
        // Settings > Home: whether attached photos and videos keep their location.
        transcript.keepLocation = { [weak services] in services?.settings?.snapshot.homeKeepLocation ?? false }
        // The first-run rows run the same registry actions as the sidebar's
        // New Terminal Tab and New Agent Chat, and show their shortcuts.
        let registry = services.registry
        transcript.onFirstRunAction = { action in
            let id: ActionID = switch action {
            case .openTerminal: Self.openTerminalAction
            case .startAgent: Self.startAgentAction
            }
            _ = registry.perform(id, invocation: ActionInvocation(origin: .user))
        }
        transcript.setFirstRunShortcuts(terminal: registry.shortcutDisplay(for: Self.openTerminalAction),
                                        agent: registry.shortcutDisplay(for: Self.startAgentAction),
                                        tabs: registry.shortcutDisplay(for: Self.selectTabByNumberAction))
        // The first-run panel waits for the first page, so a conversation
        // with history never flashes it (at once when the page is cached).
        transcript.holdsFirstRun = true
        let binding = transcript.binding
        // task-owner: lives as long as this view; ends when the first page is in
        firstPage = Task { [weak self] in
            await binding.opened()
            self?.transcript.holdsFirstRun = false
        }
        wantsLayer = true
        // The sidebar slides in from beyond the right edge: never draw it
        // over the pane next to Home.
        clipsToBounds = true
        message.alignment = .center
        message.stringValue = HomeStrings.unavailable
        addSubview(transcript)
        addSubview(message)
        // Above the transcript, so it slides in over it.
        addSubview(sidebar)
        // task-owner: lives as long as this view; event-driven (Observation)
        availability = Task { [weak self] in
            // Usable when its own owner answers: a cloud conversation (a Chief
            // placed on a server) needs no local Chief owner.
            for await (available, online, why, notice) in Observations({
                (service.isAvailable || service.isCloudConversation(id), service.homeStore.isOnline, service.unavailableMessage,
                 service.conversationNotice(for: id))
            }) {
                self?.transcript.isHidden = !available
                self?.message.isHidden = available
                self?.message.stringValue = why
                self?.transcript.showConversationNotice(notice)
                self?.needsLayout = true
                // H17: offline the user can type, but Send is off.
                self?.transcript.isSendEnabled = online
            }
        }
    }

    static let openTerminalAction: ActionID = "newSurface"
    static let startAgentAction: ActionID = "palette.newAgentChat"
    /// Ctrl-1 to 9 (a numbered family, shown as `⌃1…9`).
    static let selectTabByNumberAction: ActionID = "selectSurfaceByNumber"

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        availability?.cancel()
        engineWatch?.cancel()
        slideClient?.deactivate()
        if let toggleObserver { NotificationCenter.default.removeObserver(toggleObserver) }
        firstPage?.cancel()
        transcript.stop()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            // The pane paints under Home (`Palette.paneFill`).
            layer?.backgroundColor = nil
            message.textColor = Palette.textSecondary
        }
    }

    override func layout() {
        super.layout()
        // A layout pass mid-slide (a resize, a notice) keeps the presented
        // place: it never snaps the slide to its end.
        placeSidebar()
        let size = message.intrinsicContentSize
        message.frame = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: bounds.width, height: size.height)
    }

    /// The header avatar's click: the sidebar slides in from the right
    /// while the transcript narrows in the same frames, or out again (the
    /// Messages details panel). A click mid-slide reverses from where the
    /// panel is. Only over the Chief.
    func toggleSidebar() {
        guard isChief || slide.isOpen else { return }
        let open = !slide.isOpen
        if open { sidebar.refresh() }
        slide.setOpen(open, animated: window != nil && Motion.animatesMovement)
        placeSidebar()
        guard slide.isMoving else {
            slideClient?.deactivate()
            return
        }
        let client = slideClient ?? FrameClient(owner: "HomeHostView.sidebarSlide", view: self) { [weak self] tick in
            self?.stepSlide(tick.elapsed) ?? false
        }
        slideClient = client
        client.activate()
    }

    private func stepSlide(_ dt: Double) -> Bool {
        let moving = slide.advance(dt, policy: Motion.policy)
        placeSidebar()
        return moving
    }

    /// Places the transcript and the sidebar for the presented slide (no
    /// AppKit animator: each frame sets both frames in one transaction, so
    /// the transcript re-lays out at each width as in a live resize).
    private func placeSidebar() {
        let scale = window?.backingScaleFactor ?? 2
        let frames = slide.frames(in: bounds, sidebarWidth: HomeChiefSidebar.width, scale: scale)
        if transcript.frame != frames.transcript { transcript.frame = frames.transcript }
        if sidebar.frame != frames.sidebar { sidebar.frame = frames.sidebar }
        let hidden = !slide.isVisible
        if sidebar.isHidden != hidden { sidebar.isHidden = hidden }
    }

    /// The view that takes the keyboard when the tab's pane is focused.
    /// Home's primary input: the message box itself. Focusing the transcript
    /// view would leave it the responder after it forwards to the box.
    var focusTarget: NSView { transcript.primaryInput }
}

/// Home's primary input is its message box (R65, spec app-screens.md 3):
/// a printable key typed while Home has the keyboard but no text view of
/// it does (a click on a bubble left the transcript focused) moves the
/// keyboard to the box and types the key there.
extension HomeHostView: PrimaryInputTarget {
    var acceptsRedirectedTyping: Bool {
        guard let responder = window?.firstResponder as? NSView else { return true }
        return !(responder is NSText || responder is NSTextField)
    }

    func beginTyping(with event: NSEvent) {
        let box = transcript.primaryInput
        guard let window, window.makeFirstResponder(box) else { return }
        box.keyDown(with: event)
    }
}
