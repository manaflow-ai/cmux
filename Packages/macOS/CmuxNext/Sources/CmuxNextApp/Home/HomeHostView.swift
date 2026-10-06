import AppKit
import CmuxHomeCore
import CmuxNextDaemon
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

    init(services: AppServices, conversation: String) {
        let service = services.home
        let id = ConversationID(conversation)
        transcript = HomeNativeTranscriptView(store: service.homeStore, conversation: id, me: service.homeSource.me.id)
        sidebar = HomeChiefSidebar(muxHome: HomeBrainHost.muxHome(tag: services.environment.tag))
        super.init(frame: .zero)
        sidebar.isHidden = true
        addSubview(sidebar)
        transcript.setNamePillHelp(HomeEngineStrings.pillHelp)
        transcript.onNamePill = { [weak self] in self?.toggleSidebar() }
        transcript.avatarText = HomeChiefSidebar.readAvatar(HomeBrainHost.muxHome(tag: services.environment.tag))
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
            MainActor.assumeIsolated { self?.toggleSidebar() }
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
        // Paste, drop and the picker attach files through the store; the view
        // owns its conversation's binding (refusals, Cancel Upload).
        wantsLayer = true
        message.alignment = .center
        message.stringValue = HomeStrings.unavailable
        addSubview(transcript)
        addSubview(message)
        // task-owner: lives as long as this view; event-driven (Observation)
        availability = Task { [weak self] in
            for await (available, online) in Observations({ (service.isAvailable, service.homeStore.isOnline) }) {
                self?.transcript.isHidden = !available
                self?.message.isHidden = available
                // H17: offline the user can type, but Send is off.
                self?.transcript.isSendEnabled = online
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        availability?.cancel()
        engineWatch?.cancel()
        if let toggleObserver { NotificationCenter.default.removeObserver(toggleObserver) }
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
            MainActor.assumeIsolated {
                if !open { self?.sidebar.isHidden = true }
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
