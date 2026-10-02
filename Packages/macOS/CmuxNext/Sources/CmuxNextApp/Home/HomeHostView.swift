import AppKit
import CmuxNextDesign

/// The window's Home content. Hosts the native conversations view
/// (CmuxNextHome) fed by `HomeService`; shows why when the local daemon does
/// not serve conversations.
@MainActor
final class HomeHostView: NSView {
    private unowned let services: AppServices
    private unowned let state: WindowState
    private let message = NSTextField(labelWithString: "")

    init(services: AppServices, state: WindowState) {
        self.services = services
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        message.alignment = .center
        message.stringValue = HomeStrings.unavailable
        addSubview(message)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = Palette.pageBackground.cgColor
            message.textColor = Palette.textSecondary
        }
    }

    override func layout() {
        super.layout()
        let size = message.intrinsicContentSize
        message.frame = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: bounds.width, height: size.height)
    }

    func focusComposer() {}
}
