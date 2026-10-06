import AppKit
import CmuxHomeCore
import CmuxHomeRender
import CmuxNextActions
import CmuxNextDesign
import CmuxNextHome

/// A conversation tab's content (`conversation-tabs-v1`, home.md 7): the
/// native AppKit transcript (lane 16's `HomeNativeTranscriptView` on the
/// shared render core, home-mac.md) bound to the shared `HomeStore` over the
/// local conversation owner, or why it cannot show (the local daemon does
/// not serve conversations).
@MainActor
final class HomeHostView: NSView {
    private let transcript: HomeNativeTranscriptView
    private let binding: HomeStoreBinding
    private let message = NSTextField(labelWithString: "")
    private var availability: Task<Void, Never>?
    private var firstPage: Task<Void, Never>?

    init(services: AppServices, conversation: String) {
        let service = services.home
        let id = ConversationID(conversation)
        transcript = HomeNativeTranscriptView(conversation: id, me: service.homeSource.me.id)
        // The binding opens the conversation now and `binding.stop()` in
        // deinit closes it, however early the tab closes.
        binding = HomeStoreBinding(store: service.homeStore, controller: transcript.controller)
        super.init(frame: .zero)
        // Paste, drop and the picker attach files through the store; refusals
        // and Cancel Upload go through the binding.
        transcript.connect(binding)
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
        // task-owner: lives as long as this view; ends when the first page is in
        firstPage = Task { [weak self, binding] in
            await binding.opened()
            self?.transcript.holdsFirstRun = false
        }
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

    static let openTerminalAction: ActionID = "newSurface"
    static let startAgentAction: ActionID = "palette.newAgentChat"
    /// Ctrl-1 to 9 (a numbered family, shown as `⌃1…9`).
    static let selectTabByNumberAction: ActionID = "selectSurfaceByNumber"

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        availability?.cancel()
        firstPage?.cancel()
        binding.stop()
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
        transcript.frame = bounds
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
