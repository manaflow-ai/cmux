import AppKit
import CmuxFoundation

final class FileExplorerRowView: NSTableRowView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        observeAccentColor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeAccentColor()
    }

    private func observeAccentColor() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cmuxAccentColorDidChange(_:)),
            name: CmuxAccentColor.didChangeNotification,
            object: nil
        )
    }

    /// Redraws a selected row when `app.accentColor` changes, so the
    /// selection follows the setting without a relaunch.
    @objc private func cmuxAccentColorDidChange(_ notification: Notification) {
        if isSelected { needsDisplay = true }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let style = FileExplorerStyle.current
        let focused = isKeyboardFocusActive
        let inset = style.selectionInset
        let insetRect = bounds.insetBy(dx: inset, dy: inset > 0 ? 1 : 0)
        let path = NSBezierPath(
            roundedRect: insetRect,
            xRadius: style.selectionRadius,
            yRadius: style.selectionRadius
        )

        selectionFillColor(isFocused: focused).setFill()
        path.fill()
    }

    private var isKeyboardFocusActive: Bool {
        guard let outlineView = enclosingOutlineView else { return false }
        return window?.isKeyWindow == true && window?.firstResponder === outlineView
    }

    private var enclosingOutlineView: NSOutlineView? {
        var view = superview
        while let candidate = view {
            if let outlineView = candidate as? NSOutlineView {
                return outlineView
            }
            view = candidate.superview
        }
        return nil
    }

    private func selectionFillColor(isFocused: Bool) -> NSColor {
        Self.selectionFillColor(
            isFocused: isFocused,
            accent: AppDelegate.shared?.accentColor ?? CmuxAccentColor(),
            appearance: effectiveAppearance
        )
    }

    /// Focused selection uses the cmux accent (`app.accentColor`), like the
    /// rest of the right sidebar chrome; an unfocused selection stays neutral.
    static func selectionFillColor(
        isFocused: Bool,
        accent: CmuxAccentColor,
        appearance: NSAppearance?
    ) -> NSColor {
        if isFocused {
            return accent.nsColor(for: appearance).withAlphaComponent(0.20)
        }
        return .labelColor.withAlphaComponent(0.08)
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isKeyboardFocusActive ? .emphasized : .normal
    }
}
