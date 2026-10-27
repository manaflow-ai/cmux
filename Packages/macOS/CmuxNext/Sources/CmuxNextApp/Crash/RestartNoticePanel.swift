import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextCompat
import CmuxNextWakeups

/// "cmux restarted after a problem": a small glass panel (opaque under
/// Reduce Transparency, `Glass.makeOverlayPanel`) at the bottom of a
/// shell window, attached as a child window so it stays above Chromium page
/// windows. Non-modal and non-activating: it never becomes key, takes no
/// keyboard input, and stays until the user closes it or the window closes.
@MainActor
final class RestartNoticePanel {
    static let accessibilityID = "app.restartNotice"
    private let panel: NSPanel
    /// The stack's container inside the panel's surface; the panel is
    /// sized from it.
    private let body = ThemeChangeView()
    private weak var parent: NSWindow?
    /// The panel's size, measured once when it shows: its content (one line,
    /// fixed buttons) never changes, so a window resize only moves it.
    private var size: CGSize = .zero
    private var observers: [EventSubscription] = []
    private let onShowLog: (() -> Void)?
    private let onReport: (() -> Void)?

    init(text: String, onShowLog: (() -> Void)?, onReport: (() -> Void)? = nil) {
        self.onShowLog = onShowLog
        self.onReport = onReport
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = makeContent(text: text)
    }

    private func makeContent(text: String) -> NSView {
        // One line: a wrapping label reported one line of height in the
        // panel's fitting size and clipped the second.
        let label = ChromeLabel(labelWithString: text)
        let content = body
        content.onThemeChange = { [weak label, weak content] in
            guard let label, let content else { return }
            // The surface recolors its own material on the same change.
            content.performWithTheme { label.textColor = Palette.textPrimary }
        }
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        var views: [NSView] = [label]
        if onReport != nil {
            let report = ThemedBezelButton(title: CrashStrings.report, target: self, action: #selector(report))
            report.controlSize = .small
            views.append(report)
        }
        if onShowLog != nil {
            let show = ThemedBezelButton(title: CrashStrings.showLog, target: self, action: #selector(showLog))
            show.controlSize = .small
            views.append(show)
        }
        let close = NSButton(image: NSImage.icon(.actionClose, size: .iconFloor), target: self, action: #selector(dismiss))
        close.isBordered = false
        close.setAccessibilityLabel(CrashStrings.dismiss)
        views.append(close)
        let stack = NSStackView(views: views)
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let glass = Glass.makeOverlayPanel(content: content, cornerRadius: 12)
        glass.setAccessibilityIdentifier(Self.accessibilityID)
        glass.setAccessibilityLabel(text)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return glass
    }

    /// Attaches to `window` (bottom center) and follows its resizes. `center` is where the window posts (tests
    /// pass their own).
    func show(on window: NSWindow, center: NotificationCenter = .default) {
        parent = window
        window.addChildWindow(panel, ordered: .above)
        window.themeScope.adopt(panel)
        // The constraint engine's fitting size: a one-line label and fixed buttons need no layout to measure.
        size = body.fittingSize
        place()
        // The window's one observer per notice (WindowEvents): the notice follows its frame and closes with it.
        let events = WindowEvents.of(window, center: center)
        observers = [
            events.subscribe(NSWindow.didResizeNotification, owner: "RestartNotice.place") { [weak self] in self?.place() },
            events.subscribe(NSWindow.didMoveNotification, owner: "RestartNotice.place") { [weak self] in self?.place() },
            events.subscribe(NSWindow.willCloseNotification, owner: "RestartNotice.dismiss") { [weak self] in self?.dismiss() },
        ]
    }

    var isShown: Bool { panel.parent != nil }
    /// The notice's material: glass, or opaque under Reduce Transparency.
    var surface: OverlaySurfaceView? { panel.contentView as? OverlaySurfaceView }
    var text: String { (panel.contentView?.accessibilityLabel()) ?? "" }

    private func place() {
        guard let parent else { return }
        let frame = parent.frame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 16, width: size.width, height: size.height), display: true)
    }

    @objc private func showLog() { onShowLog?() }

    @objc private func report() { onReport?() }

    @objc func dismiss() {
        observers.removeAll()
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
