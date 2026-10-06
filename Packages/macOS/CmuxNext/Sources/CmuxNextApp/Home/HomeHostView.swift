import AppKit
import CmuxHomeCore
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
    /// The Chief's engine (harness, model, effort, last turn), over the
    /// Chief conversation only.
    private let engineBar: HomeEngineBar
    private var engineWatch: Task<Void, Never>?
    private static let engineBarHeight: CGFloat = 28

    init(services: AppServices, conversation: String) {
        let service = services.home
        let id = ConversationID(conversation)
        transcript = HomeNativeTranscriptView(store: service.homeStore, conversation: id, me: service.homeSource.me.id)
        engineBar = HomeEngineBar(muxHome: HomeBrainHost.muxHome(tag: services.environment.tag))
        super.init(frame: .zero)
        engineBar.isHidden = true
        addSubview(engineBar)
        let store = service.homeStore
        // task-owner: lives as long as this view; event-driven (Observation):
        // shown for the Chief conversation, refreshed on each new message.
        engineWatch = Task { [weak self] in
            for await (isChief, _) in Observations({ () -> (Bool, Int) in
                let chief = store.rows.first { $0.summary.id == id }?.summary.participants.contains { $0.agentClass == .chief } ?? false
                return (chief, store.transcriptVersion[id] ?? 0)
            }) {
                guard let self else { return }
                if engineBar.isHidden == isChief {
                    engineBar.isHidden = !isChief
                    needsLayout = true
                }
                if isChief { engineBar.refresh() }
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
        let bar = engineBar.isHidden ? 0 : Self.engineBarHeight
        engineBar.frame = NSRect(x: 0, y: bounds.height - bar, width: bounds.width, height: bar)
        transcript.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - bar)
        let size = message.intrinsicContentSize
        message.frame = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: bounds.width, height: size.height)
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
