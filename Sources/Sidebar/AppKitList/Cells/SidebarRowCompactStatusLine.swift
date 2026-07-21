import AppKit
import CmuxWorkspaces
import SwiftUI

// MARK: - Compact status line (hidesAllDetails mode)

/// Pure-AppKit port of the legacy `compactWorkspaceStatusMenu` row: a flag
/// glyph plus "Status: X" that opens the status-lane menu on press. Shown
/// only in compact detail mode (`hidesAllDetails`) for workspaces with a
/// visible status.
@MainActor
final class SidebarRowCompactStatusLine: NSControl {
    private let iconView = NSImageView()
    private let label = SidebarRowTextView(lines: 1)

    var menuProvider: (() -> NSMenu)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        addSubview(label)
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
        label.stringValue = String(
            localized: "sidebar.status.compactLabel",
            defaultValue: "Status: \(status.displayName)"
        )
        label.font = .systemFont(ofSize: model.scaled(10), weight: .semibold)
        label.textColor = palette.secondary(0.9)
        toolTip = String(localized: "sidebar.status.compactTooltip", defaultValue: "Change workspace status")
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("SidebarWorkspaceCompactStatusMenu")
        needsLayout = true
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        let iconSide = iconView.image?.size.height ?? 0
        return max(iconSide, label.sidebarNaturalCellSize.height)
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
        let labelSize = label.sidebarNaturalCellSize
        let labelX = iconSize.width > 0 ? iconSize.width + 4 : 0
        label.frame = NSRect(
            x: labelX,
            y: (bounds.height - labelSize.height) / 2,
            width: max(10, bounds.width - labelX),
            height: labelSize.height
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
