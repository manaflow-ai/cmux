import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// A glass panel docked over the bottom of the System Settings window while
/// a grant is pending: an arrow up to the list, "Drag cmux Computer Use to
/// the list above to allow Screenshots", and the helper app's row to drag.
/// It never takes focus, so System Settings stays the active app. It waits
/// at the bottom center of the screen until the System Settings window is
/// on screen (a few reads while System Settings opens), then docks to it.
final class HelperDragPanel: NSPanel {
    static let width: CGFloat = 440
    private static let padding: CGFloat = 12
    private let onClose: () -> Void
    private var locating: Task<Void, Never>?
    private var fallbackScreen: NSScreen?

    init(appURL: URL, grant: String, onClose: @escaping () -> Void, onDrop: @escaping () -> Void) {
        self.onClose = onClose
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        level = .floating
        animationBehavior = Motion.overlays.animatesMovement ? .utilityWindow : .none
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        let inner = Self.width - 2 * Self.padding
        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil) ?? NSImage())
        arrow.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        arrow.contentTintColor = Palette.textPrimary
        arrow.setContentHuggingPriority(.required, for: .horizontal)
        let helper = HelperAppTile.displayName(appURL)
        let line = OnboardingLabel.make(font: Typography.system(size: TypeScale.body), lines: 2)
        line.attributedStringValue = Self.dragLine(helper: helper, grant: grant)
        line.preferredMaxLayoutWidth = inner - 15 - 10 - 20 - 10
        line.setContentCompressionResistancePriority(.keepsTextWidth, for: .horizontal)
        let close = HelperPanelCloseButton(target: nil, action: nil)
        close.setContentHuggingPriority(.required, for: .horizontal)
        let top = NSStackView(views: [arrow, line, close])
        top.alignment = .centerY
        top.spacing = 10
        top.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        let tile = HelperAppTile(appURL: appURL)
        tile.onDrop = onDrop
        let row = HelperRowFill(content: tile)
        let stack = NSStackView(views: [top, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        NSLayoutConstraint.activate([
            top.widthAnchor.constraint(equalToConstant: inner),
            row.widthAnchor.constraint(equalToConstant: inner),
        ])
        let size = NSSize(width: Self.width, height: stack.fittingSize.height)
        let surface = Glass.makeOverlayPanel(content: stack)
        // A window's content view sizes by its frame, not constraints.
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.frame = NSRect(origin: .zero, size: size)
        surface.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: size)
        contentView = surface
        ThemeScope.app.store.adopt(self)
        setContentSize(size)
        close.target = self
        close.action = #selector(closePressed)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @objc private func closePressed() { onClose() }

    /// "Drag **helper** to the list above to allow **grant**": the two names bold.
    static func dragLine(helper: String, grant: String) -> NSAttributedString {
        let text = OnboardingStrings.computerUseDragLine(helper: helper, grant: grant)
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: Typography.system(size: TypeScale.body), .foregroundColor: Palette.textSecondary,
        ])
        let bold: [NSAttributedString.Key: Any] = [.font: Typography.system(size: TypeScale.body, weight: TypeScale.emphasis),
                                                   .foregroundColor: Palette.textPrimary]
        for name in [helper, grant] {
            let range = (text as NSString).range(of: name)
            if range.location != NSNotFound { result.addAttributes(bold, range: range) }
        }
        return result
    }

    /// Shows the panel docked to System Settings (or at the bottom center of
    /// `screen` until a System Settings window is on screen).
    func show(on screen: NSScreen?) {
        fallbackScreen = screen ?? NSScreen.main
        if let visible = fallbackScreen?.visibleFrame {
            setFrame(SystemSettingsWindow.fallbackFrame(panel: frame.size, visible: visible), display: false)
        }
        alphaValue = 0
        orderFrontRegardless()
        Motion.overlays.animate(.fadeIn, in: contentView) { animator().alphaValue = 1 }
        dock()
    }

    /// Reads before the panel stays at its fallback place: System Settings
    /// may still be opening when Allow shows the panel.
    static let dockReads = 6

    /// Moves the panel over the bottom of the System Settings window.
    private func dock() {
        locating?.cancel()
        // task-owner: a few window list reads while System Settings opens; orderOut cancels them.
        locating = Task { [weak self] in
            var backoff = Backoff(initial: .milliseconds(150), maximum: .seconds(1), jitter: 0)
            for _ in 0..<Self.dockReads {
                if let settings = await SystemSettingsWindow.frontFrame() {
                    guard let self, !Task.isCancelled, isVisible else { return }
                    let screen = NSScreen.screens.first { $0.frame.intersects(settings) } ?? fallbackScreen
                    let target = SystemSettingsWindow.dockedFrame(panel: frame.size, settings: settings, visible: screen?.visibleFrame)
                    if target != frame { Motion.overlays.animateTimed(.panel, in: contentView) { animator().setFrame(target, display: true) } }
                    return
                }
                // concurrency-allow: Backoff.wait spaces a few reads after one found no window, not a poll period.
                do { try await backoff.wait(owner: "onboarding.helper-panel.dock") } catch { return }
            }
        }
    }

    override func orderOut(_ sender: Any?) {
        locating?.cancel()
        locating = nil
        super.orderOut(sender)
    }
}

/// The helper app's row in the panel: a solid rounded fill under the tile.
private final class HelperRowFill: NSView {
    private var loop: RenderLoop?

    init(content: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        loop = RenderLoop { [weak self] in
            _ = ThemeScope.app.store.input
            self?.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme { layer?.backgroundColor = Palette.textPrimary.withAlphaComponent(0.06).cgColor }
    }
}
