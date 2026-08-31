import AppKit
import CmuxWorkspaces

// MARK: - Compact status line (hidesAllDetails mode)

/// Pure-AppKit port of the legacy `compactWorkspaceStatusMenu` row: a flag
/// glyph that opens the status-lane menu on press. The status glyph in the
/// title line carries the visible status; this compact affordance remains for
/// menu access when details are hidden.
@MainActor
final class SidebarRowCompactStatusLine: NSControl {
    private let iconView = NSImageView()

    var menuProvider: (() -> NSMenu)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        status: WorkspaceTaskStatus,
        model: SidebarWorkspaceRowModel,
        palette: SidebarRowPalette
    ) {
        iconView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "flag", pointSize: model.scaled(8), weight: nil
        )
        iconView.contentTintColor = palette.secondary(0.65)
        toolTip = String(localized: "sidebar.status.compactTooltip", defaultValue: "Change workspace status")
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("SidebarWorkspaceCompactStatusMenu")
        setAccessibilityLabel(String(
            localized: "sidebar.status.compactLabel",
            defaultValue: "Status: \(status.displayName)"
        ))
        needsLayout = true
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        iconView.image?.size.height ?? 0
    }

    override func layout() {
        super.layout()
        let iconSize = iconView.image?.size ?? .zero
        iconView.frame = NSRect(
            x: 0,
            y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width,
            height: iconSize.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        // Legacy SwiftUI `Menu` opens on press, not on release; dim while
        // the menu tracks (popUp blocks until dismissal).
        presentLanesMenu()
    }

    /// VoiceOver/keyboard activation parity with the legacy SwiftUI Menu.
    override func accessibilityPerformPress() -> Bool {
        guard menuProvider != nil else { return false }
        presentLanesMenu()
        return true
    }

    private func presentLanesMenu() {
        guard let menu = menuProvider?() else { return }
        alphaValue = SidebarRowPressedDim.pressedAlpha
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
        alphaValue = 1
    }
}
