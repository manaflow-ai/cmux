import AppKit
import CmuxNextDesign

/// "Restart Shell Here" above the status banner while the terminal's shell
/// has ended (`tab.restart`). Shown only when the App gave an action (a
/// daemon with `tab-restart-v1`). The theme's secondary text on its selection
/// fill, no accent, like the banner.
final class TerminalRestartButton: ClickableButton {
    var onRestart: (@MainActor () -> Void)? {
        didSet { refresh() }
    }

    private var exited = false

    init() {
        let title = ModuleResourceBundle.terminal.text("terminal.restart.button", defaultValue: "Restart Shell Here")
        super.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        imagePosition = .imageLeading
        bezelStyle = .rounded
        font = .systemFont(ofSize: 12, weight: .medium)
        setAccessibilityLabel(title)
        target = self
        action = #selector(clicked)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeTint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeTint()
    }

    private func applyThemeTint() {
        performWithTheme {
            contentTintColor = Palette.textSecondary
            bezelColor = Palette.selectionFill
        }
    }

    /// Follows the link status: visible only while the shell has ended.
    func show(_ status: TerminalConnectionStatus) {
        exited = status == .exited
        refresh()
    }

    private func refresh() {
        isHidden = !exited || onRestart == nil
    }

    @objc private func clicked() { onRestart?() }
}
