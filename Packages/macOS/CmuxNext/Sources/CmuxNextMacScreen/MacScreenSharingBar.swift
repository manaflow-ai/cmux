import AppKit
import CmuxNextDesign

/// A persistent, first-class host affordance shown while a device is viewing or controlling this
/// Mac. It deliberately sits outside cmux's main window so the person can stop sharing while using
/// another app.
@MainActor
final class MacScreenSharingBar: NSPanel {
    private let root = MacScreenThemedView(frame: .zero)
    private let titleLabel = MacScreenText("", font: MacScreenType.body, ink: \.primary, wraps: false)
    private lazy var stopButton = MacScreenButton(
        L.t("macScreen.indicator.stop", "Stop Sharing"), role: .destructive, compact: true,
        id: "macScreen.sharingBar.stop") { [weak self] in self?.onStop?() }
    private var onStop: (() -> Void)?

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        becomesKeyOnlyIfNeeded = true
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView = root

        let background = MacScreenFill(\.popup, shape: .rounded(Metrics.panelCornerRadius), bordered: true)
        root.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: root.leadingAnchor), background.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            background.topAnchor.constraint(equalTo: root.topAnchor), background.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        let dot = MacScreenFill.dot(\.litGlyph, side: Metrics.space2)
        let textColumn = MacScreenStack.make(.vertical, spacing: Metrics.space1, alignment: .leading, [titleLabel,
            MacScreenText(L.t("macScreen.indicator.sharing", "Screen sharing is on"), font: MacScreenType.caption, ink: \.secondary)])
        textColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = MacScreenStack.make(.horizontal, spacing: Metrics.space3, alignment: .centerY,
                                      [dot, textColumn, MacScreenSpacer(), stopButton],
                                      insets: NSEdgeInsets(top: Metrics.space3, left: Metrics.space4,
                                                           bottom: Metrics.space3, right: Metrics.space4))
        root.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: root.leadingAnchor), row.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            row.topAnchor.constraint(equalTo: root.topAnchor), row.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.wantsLayer = true
        root.layer?.cornerRadius = Metrics.panelCornerRadius
        root.layer?.cornerCurve = .continuous
        root.setAccessibilityIdentifier("macScreen.sharingBar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(title: String, onStop: @escaping () -> Void) {
        titleLabel.stringValue = title
        titleLabel.setAccessibilityLabel(title)
        self.onStop = onStop
        root.resolveColors()
        root.layoutSubtreeIfNeeded()
    }

    func show() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        root.resolveColors()
        root.layoutSubtreeIfNeeded()
        let fitting = root.fittingSize
        let width = min(fitting.width, screen.visibleFrame.width - 2 * Metrics.space4)
        let height = max(fitting.height, Metrics.controlHeight + 2 * Metrics.space4)
        let frame = NSRect(x: screen.visibleFrame.midX - width / 2,
                           y: screen.visibleFrame.maxY - height - Metrics.space4,
                           width: width, height: height)
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}
