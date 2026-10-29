import AppKit
import CmuxNextDesign

/// "Retry" above the status banner once a terminal view's attach kept failing
/// (cx-wwtam; it still retries by itself): a re-attach now. A click or a key in
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

    /// Visible only while the view is disconnected and its attach kept failing
    /// (never for an administrator's block: it cannot reconnect).
    func show(_ status: TerminalConnectionStatus) {
        isHidden = !Self.shows(status)
    }

    /// Whether `status` shows the button (the host builds it the first time one does).
    static func shows(_ status: TerminalConnectionStatus) -> Bool {
        switch status {
        case .disconnected(.turnedOffByOrganization, _): false
        case .disconnected(_, reconnecting: false): true
        case .connected, .restoring, .disconnected, .exited: false
        }
    }

    @objc private func clicked() { onRetry?() }
}
