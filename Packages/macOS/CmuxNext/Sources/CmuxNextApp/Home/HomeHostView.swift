import AppKit
import CmuxHomeCore
import CmuxHomeRender
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

    init(services: AppServices, conversation: String) {
        let service = services.home
        let id = ConversationID(conversation)
        transcript = HomeNativeTranscriptView(conversation: id, me: service.homeSource.me.id)
        binding = HomeStoreBinding(store: service.homeStore, controller: transcript.controller)
        super.init(frame: .zero)
        // Paste, drop and the picker attach files through the store; refusals
        // and Cancel Upload go through the binding.
        transcript.connect(binding)
        wantsLayer = true
        message.alignment = .center
        message.stringValue = HomeStrings.unavailable
        addSubview(transcript)
        addSubview(message)
        // task-owner: one snapshot read; ends with its reply
        Task { await service.homeStore.open(id) }
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
