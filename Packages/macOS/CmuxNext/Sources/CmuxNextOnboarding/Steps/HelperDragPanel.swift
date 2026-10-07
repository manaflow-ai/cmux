import AppKit
import CmuxNextDesign

/// A small floating panel over System Settings while a grant is pending:
/// the helper app's tile to drag into the open list, one line on what to
/// do, and a close button. It never takes focus, so System Settings stays
/// the active app.
final class HelperDragPanel: NSPanel {
    private let onClose: () -> Void

    init(appURL: URL, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        level = .floating
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        let tile = HelperAppTile(appURL: appURL)
        let line = OnboardingLabel.make(OnboardingStrings.computerUseHelperDrag, font: OnboardingMetrics.captionFont,
                                        color: Palette.textSecondary, lines: 2)
        line.preferredMaxLayoutWidth = 220
        let close = HelperPanelCloseButton(target: nil, action: nil)
        let stack = NSStackView(views: [tile, line, close])
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 12)
        let size = stack.fittingSize
        let surface = Glass.makeOverlayPanel(content: stack)
        // A window's content view sizes by its frame, not constraints.
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.frame = NSRect(origin: .zero, size: size)
        surface.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: size)
        contentView = surface
        ThemeStore.shared.adopt(self)
        setContentSize(size)
        close.target = self
        close.action = #selector(closePressed)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @objc private func closePressed() { onClose() }

    /// Bottom center of the screen System Settings opens on, clear of the Dock.
    func show(on screen: NSScreen?) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + 48))
        orderFrontRegardless()
    }
}
