import AppKit
import SwiftUI

/// Single-line AppKit text field used for inline workspace renaming in the
/// sidebar. SwiftUI's `TextField` can't control selection/caret or distinguish a
/// first vs second Escape, so this bridges `NSTextField`. Inputs are value +
/// closures only (no store reference), per the sidebar snapshot-boundary rule.
struct SidebarInlineRenameField: NSViewRepresentable {
    let initialText: String
    let fontSize: CGFloat
    let textColor: NSColor
    let accessibilityLabel: String
    let placeholder: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    /// Creates the delegate coordinator that bridges field-editor commands and
    /// focus loss to the `onCommit` / `onCancel` closures.
    func makeCoordinator() -> SidebarInlineRenameCoordinator {
        SidebarInlineRenameCoordinator(onCommit: onCommit, onCancel: onCancel)
    }

    /// Builds the borderless, single-line text field seeded with `initialText`
    /// and wired to the coordinator.
    func makeNSView(context: Context) -> SidebarInlineRenameTextField {
        let field = SidebarInlineRenameTextField(string: initialText)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
        field.inlineRenameTextColor = textColor
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel)
        field.delegate = context.coordinator
        return field
    }

    /// Refreshes the coordinator's closures and the field's driven visual and
    /// accessibility state on each parent update (never its text — see below).
    func updateNSView(_ nsView: SidebarInlineRenameTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        // Keep driven visual/accessibility state in sync (NSViewRepresentable
        // convention). initialText/stringValue is intentionally NOT synced here:
        // doing so would reset the cursor and clobber in-progress typing.
        nsView.font = .systemFont(ofSize: fontSize, weight: .semibold)
        nsView.inlineRenameTextColor = textColor
        nsView.placeholderString = placeholder
        nsView.setAccessibilityLabel(accessibilityLabel)
    }
}
