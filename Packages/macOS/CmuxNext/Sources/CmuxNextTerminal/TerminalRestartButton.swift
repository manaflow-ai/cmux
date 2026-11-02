import AppKit
import CmuxNextDesign

/// "Restart Shell Here" above the status banner while the terminal's shell
/// has ended, and "Recover" while cmux lost its link to a shell that may
/// still run (both `tab.restart`: the daemon rehosts a failed link's shell
/// in place). Shown only when the App gave an action (a daemon with
/// `tab-restart-v1`). The theme's secondary text on its selection fill, no
/// accent, like the banner.
final class TerminalRestartButton: ClickableButton {
    var onRestart: (@MainActor () -> Void)? {
        didSet { refresh() }
    }

    private var exited = false
    private var linkLost = false

    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        imagePosition = .imageLeading
        bezelStyle = .rounded
        font = .systemFont(ofSize: 12, weight: .medium)
        applyTitle()
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

    /// Follows the link status: visible while the shell has ended, or while
    /// cmux lost its link to it (`stall` `.linkLost`).
    func show(_ status: TerminalConnectionStatus, stall: TerminalShellStall? = nil) {
        exited = status == .exited
        linkLost = !exited && stall == .linkLost
        applyTitle()
        refresh()
    }

    /// The button's title for what it does now.
    var shownTitle: String { title }

    private func applyTitle() {
        let strings = ModuleResourceBundle.terminal
        let text = linkLost
            ? strings.text("terminal.recover.button", defaultValue: "Recover")
            : strings.text("terminal.restart.button", defaultValue: "Restart Shell Here")
        guard title != text else { return }
        title = text
        setAccessibilityLabel(text)
    }

    private func refresh() {
        isHidden = !(exited || linkLost) || onRestart == nil
    }

    @objc private func clicked() { onRestart?() }
}
