import AppKit
import CmuxNextDesign

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
    private var observers: [any NSObjectProtocol] = []
    private let onShowLog: (() -> Void)?

    init(text: String, onShowLog: (() -> Void)?) {
        self.onShowLog = onShowLog
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
        let label = NSTextField(labelWithString: text)
        let content = body
        content.onThemeChange = { [weak label, weak content] in
            guard let label, let content else { return }
            // The surface recolors its own material on the same change.
            content.performWithTheme { label.textColor = Palette.textPrimary }
        }
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        var views: [NSView] = [label]
        if onShowLog != nil {
            let show = NSButton(title: CrashStrings.showLog, target: self, action: #selector(showLog))
            show.bezelStyle = .accessoryBarAction
            views.append(show)
        }
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: CrashStrings.dismiss) ?? NSImage(),
                             target: self, action: #selector(dismiss))
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

    /// Attaches to `window` (bottom center) and follows its resizes.
    func show(on window: NSWindow) {
        parent = window
        window.addChildWindow(panel, ordered: .above)
        window.themeScope.adopt(panel)
        place()
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    var isShown: Bool { panel.parent != nil }
    /// The notice's material: glass, or opaque under Reduce Transparency.
    var surface: OverlaySurfaceView? { panel.contentView as? OverlaySurfaceView }
    var text: String { (panel.contentView?.accessibilityLabel()) ?? "" }

    private func place() {
        guard let parent else { return }
        body.layoutSubtreeIfNeeded()
        let size = body.fittingSize
        let frame = parent.frame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 16, width: size.width, height: size.height), display: true)
    }

    @objc private func showLog() { onShowLog?() }

    @objc func dismiss() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
