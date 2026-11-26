import AppKit
import CmuxWorkspaces
import SwiftUI

// MARK: - Summary line

/// The one-line progress summary: leading `checklist` glyph
/// (`checkmark.circle.fill` when everything is done), a monospaced-digit
/// "completed/total" count, and — while anything is unchecked — a dim "·"
/// plus first-unchecked-item preview. The whole line is one full-width click
/// target (legacy: the Button's contentShape spans the row).
@MainActor
final class SidebarRowChecklistSummaryLine: NSControl {
    private let iconView = NSImageView()
    private let countLabel = SidebarRowTextView(lines: 1)
    private let separatorLabel = SidebarRowTextView(lines: 1)
    private let previewLabel = SidebarRowTextView(lines: 1)
    private var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        addSubview(countLabel)
        separatorLabel.isHidden = true
        addSubview(separatorLabel)
        previewLabel.isHidden = true
        addSubview(previewLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot,
        model: SidebarWorkspaceRowModel,
        primary: NSColor,
        secondary: NSColor,
        toolTip: String,
        onClick: @escaping () -> Void
    ) {
        self.onClick = onClick
        self.toolTip = toolTip
        let allDone = snapshot.checklistCompletedCount == snapshot.checklistTotalCount
        iconView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: allDone ? "checkmark.circle.fill" : "checklist",
            pointSize: model.scaled(8),
            weight: nil
        )
        iconView.contentTintColor = secondary
        let summaryFont = NSFont.monospacedDigitSystemFont(ofSize: model.scaled(10), weight: .semibold)
        let itemFont = NSFont.systemFont(ofSize: model.scaled(10))
        countLabel.stringValue = "\(snapshot.checklistCompletedCount)/\(snapshot.checklistTotalCount)"
        countLabel.font = summaryFont
        countLabel.textColor = primary
        let preview = snapshot.checklistFirstUncheckedText
        separatorLabel.isHidden = preview == nil
        previewLabel.isHidden = preview == nil
        if let preview {
            separatorLabel.stringValue = "·"
            separatorLabel.font = summaryFont
            separatorLabel.textColor = secondary
            previewLabel.stringValue = preview
            previewLabel.font = itemFont
            previewLabel.textColor = secondary
        }
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("SidebarChecklistSummaryLine")
        var accessibilityText = countLabel.stringValue
        if let preview, !preview.isEmpty {
            accessibilityText += " · " + preview
        }
        setAccessibilityLabel(accessibilityText)
        countLabel.setAccessibilityElement(false)
        separatorLabel.setAccessibilityElement(false)
        previewLabel.setAccessibilityElement(false)
        needsLayout = true
    }

    func resetForReuse() {
        onClick = nil
        toolTip = nil
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        let iconHeight = iconView.image?.size.height ?? 0
        var height = max(iconHeight, countLabel.sidebarNaturalCellSize.height)
        if !previewLabel.isHidden {
            height = max(height, previewLabel.sidebarNaturalCellSize.height)
        }
        return ceil(height)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        let iconSize = iconView.image?.size ?? .zero
        iconView.frame = NSRect(
            x: 0, y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width, height: iconSize.height
        )
        x += iconSize.width + 4
        let countSize = countLabel.sidebarNaturalCellSize
        countLabel.frame = NSRect(
            x: x, y: (bounds.height - countSize.height) / 2,
            width: ceil(countSize.width), height: countSize.height
        )
        x += ceil(countSize.width) + 4
        if !separatorLabel.isHidden {
            let separatorSize = separatorLabel.sidebarNaturalCellSize
            separatorLabel.frame = NSRect(
                x: x, y: (bounds.height - separatorSize.height) / 2,
                width: ceil(separatorSize.width), height: separatorSize.height
            )
            x += ceil(separatorSize.width) + 4
            let previewSize = previewLabel.sidebarNaturalCellSize
            previewLabel.frame = NSRect(
                x: x, y: (bounds.height - previewSize.height) / 2,
                width: max(0, bounds.width - x), height: previewSize.height
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Swallow so the table row action does not also fire (legacy Button
        // consumes the click without selecting the row), and dim while
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
