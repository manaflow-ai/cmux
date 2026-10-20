import AppKit
import CmuxWorkspaces
import SwiftUI

/// The ghost "+ Add item" button (icon + label, single click target).
@MainActor
final class SidebarRowChecklistGhostAddButton: NSControl {
    private let iconView = NSImageView()
    private let label = SidebarRowTextView(lines: 1)
    private var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("SidebarChecklistAddItemRow")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        iconPointSize: CGFloat,
        title: String,
        font: NSFont,
        color: NSColor,
        onClick: @escaping () -> Void
    ) {
        self.onClick = onClick
        iconView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "plus", pointSize: iconPointSize, weight: nil
        )
        iconView.contentTintColor = color
        label.stringValue = title
        label.font = font
        label.textColor = color
        // The custom control does not combine its child text into an
        // accessible name the way the SwiftUI Button it replaces did.
        setAccessibilityLabel(title)
        label.setAccessibilityElement(false)
        needsLayout = true
    }

    func measuredWidth() -> CGFloat {
        let iconWidth = iconView.image?.size.width ?? 0
        return ceil(iconWidth + 4 + label.sidebarNaturalCellSize.width)
    }

    func measuredHeight() -> CGFloat {
        let iconHeight = iconView.image?.size.height ?? 0
        return ceil(max(iconHeight, label.sidebarNaturalCellSize.height))
    }

    override func layout() {
        super.layout()
        let iconSize = iconView.image?.size ?? .zero
        iconView.frame = NSRect(
            x: 0, y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width, height: iconSize.height
        )
        let labelSize = label.sidebarNaturalCellSize
        label.frame = NSRect(
            x: iconSize.width + 4, y: (bounds.height - labelSize.height) / 2,
            width: max(0, bounds.width - iconSize.width - 4), height: labelSize.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        // Swallow so the table row action does not also fire; dim while
        // pressed like the SwiftUI plain Button this ports.
        alphaValue = SidebarRowPressedDim.pressedAlpha
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }

    /// VoiceOver/keyboard activation parity with the legacy SwiftUI Button.
    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}
