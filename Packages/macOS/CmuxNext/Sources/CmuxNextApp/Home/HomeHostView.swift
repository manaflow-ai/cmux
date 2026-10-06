import AppKit
import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextActions
import CmuxNextDesign
import CmuxNextHome

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
    private var sidebarOpen = false
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
                if !isChief, sidebarOpen { toggleSidebar() }
                if sidebarOpen { sidebar.refresh() }
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
                 service.migrationNotice)
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
        let side = sidebarOpen ? HomeChiefSidebar.width : 0
        transcript.frame = NSRect(x: 0, y: 0, width: bounds.width - side, height: bounds.height)
        sidebar.frame = NSRect(x: bounds.width - side, y: 0, width: HomeChiefSidebar.width, height: bounds.height)
        let size = message.intrinsicContentSize
        message.frame = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: bounds.width, height: size.height)
    }

    /// The name pill's click: the sidebar slides in from the right (the
    /// transcript narrows with it) or out again. Only over the Chief.
    func toggleSidebar() {
        guard isChief || sidebarOpen else { return }
        sidebarOpen.toggle()
        if sidebarOpen {
            sidebar.refresh()
            sidebar.frame = NSRect(x: bounds.width, y: 0, width: HomeChiefSidebar.width, height: bounds.height)
            sidebar.isHidden = false
        }
        let side = sidebarOpen ? HomeChiefSidebar.width : 0
        let open = sidebarOpen
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.allowsImplicitAnimation = true
            transcript.animator().frame = NSRect(x: 0, y: 0, width: bounds.width - side, height: bounds.height)
            sidebar.animator().frame = NSRect(x: bounds.width - side, y: 0, width: HomeChiefSidebar.width, height: bounds.height)
        }, completionHandler: { [weak self] in
            // task-owner: one hop to the main actor when the slide ends
            Task { @MainActor in
                if !open, self?.sidebarOpen == false { self?.sidebar.isHidden = true }
            }
        })
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
