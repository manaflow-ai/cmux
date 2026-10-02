import AppKit
import CmuxNextDesign
import CmuxNextHome

/// A conversation tab's content (`conversation-tabs-v1`, home.md 7): the
/// native conversations view (CmuxNextHome) fed by this tab's
/// `HomeWindowModel`, opened on the tab's conversation, or why it cannot show
/// (the local daemon does not serve conversations).
@MainActor
final class HomeHostView: NSView {
    private unowned let services: AppServices
    private let model: HomeWindowModel
    private let home: HomeView
    private let message = NSTextField(labelWithString: "")
    private var availability: Task<Void, Never>?

    init(services: AppServices, conversation: String) {
        self.services = services
        model = HomeWindowModel(service: services.home, conversation: conversation)
        home = HomeView(viewModel: model.viewModel)
        super.init(frame: .zero)
        wantsLayer = true
        message.alignment = .center
        message.stringValue = HomeStrings.unavailable
        addSubview(home)
        addSubview(message)
        let service = services.home
        // task-owner: lives as long as this view; event-driven (Observation)
        availability = Task { [weak self] in
            for await available in Observations({ service.isAvailable }) {
                self?.home.isHidden = !available
                self?.message.isHidden = available
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit { availability?.cancel() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = Palette.pageBackground.cgColor
            message.textColor = Palette.textSecondary
        }
    }

    override func layout() {
        super.layout()
        home.frame = bounds
        let size = message.intrinsicContentSize
        message.frame = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: bounds.width, height: size.height)
    }

    /// The view that takes the keyboard when the tab's pane is focused.
    var focusTarget: NSView { home }
}
