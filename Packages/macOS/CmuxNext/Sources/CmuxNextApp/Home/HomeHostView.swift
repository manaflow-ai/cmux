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
        wantsLayer = true
        message.alignment = .center
        message.stringValue = HomeStrings.unavailable
        addSubview(transcript)
        addSubview(message)
        // task-owner: one snapshot read; ends with its reply
        Task { await service.homeStore.open(id) }
        // task-owner: lives as long as this view; event-driven (Observation)
        availability = Task { [weak self] in
            for await available in Observations({ service.isAvailable }) {
                self?.transcript.isHidden = !available
                self?.message.isHidden = available
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
            layer?.backgroundColor = Palette.pageBackground.cgColor
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
    var focusTarget: NSView { transcript }
}
