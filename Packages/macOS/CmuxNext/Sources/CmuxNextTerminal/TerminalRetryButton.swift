import AppKit
import CmuxNextDesign

/// "Retry" above the status banner once a terminal view stopped retrying its
/// attach by itself (cx-wwtam): a re-attach now, with its retries back. A click or a key in
/// the terminal does the same; the button says so where it can be seen.
/// Styled like ``TerminalRestartButton``.
final class TerminalRetryButton: NSButton {
    var onRetry: (@MainActor () -> Void)?

    init() {
        let title = ModuleResourceBundle.terminal.text("terminal.retry.button", defaultValue: "Retry")
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

    /// Visible only while the view is disconnected and no longer retrying
    /// (never for an administrator's block: it cannot reconnect).
    func show(_ status: TerminalConnectionStatus) {
        switch status {
        case .disconnected(.turnedOffByOrganization, _): isHidden = true
        case .disconnected(_, reconnecting: false): isHidden = false
        case .connected, .restoring, .disconnected, .exited: isHidden = true
        }
    }

    @objc private func clicked() { onRetry?() }
}
