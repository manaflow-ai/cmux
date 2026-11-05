import AppKit
import CmuxNextDesign

/// The sidebar's edit mode on one item (Leo 2026-10-20, as an iPhone's home screen): the item
/// wiggles through the sidebar's motion gate (still under Reduce Motion or with sidebar animations
/// off), shows a ✕ that takes it out of the sidebar (`onRemove`; Delete does the same from the
/// keyboard), and a press only drags it (`mouseDown`, `mouseUp`).
extension SidebarItemRowView {
    static let wiggleKey = "cmux.sidebar.editWiggle"

    func editingChanged() {
        if isEditing, onRemove != nil, removeButton == nil {
            let button = SidebarIconButton(icon: .actionClose, pointSize: { Metrics.smallIconSize - Metrics.space2 }, label: "")
            button.onPress = { [weak self] in self?.onRemove?() }
            addSubview(button)
            removeButton = button
        } else if !isEditing {
            removeButton?.removeFromSuperview()
            removeButton = nil
        }
        // A new wiggle for the new state: added, or taken off.
        wiggleSize = .zero
        needsLayout = true
    }

    /// Places the ✕ and starts the wiggle (again when the item's size changed: it turns about its middle).
    func layoutEditing() {
        // The ✕ takes the unread badge's place on a row.
        badge.alphaValue = isEditing ? 0 : 1
        rowBadge.alphaValue = isEditing ? 0 : 1
        guard isEditing else {
            layer?.removeAnimation(forKey: Self.wiggleKey)
            return
        }
        if let removeButton {
            let side = Metrics.smallIconSize + Metrics.space1
            // A row: at its trailing end; a tile or icon: on its top leading corner, as on an iPhone.
            let iconOnly = style.isIconOnly || style == .favorite
            removeButton.frame = iconOnly ? NSRect(x: 0, y: 0, width: side, height: side)
                : SidebarStyle.trailingColumnFrame(rowWidth: bounds.width - SidebarStyle.horizontalInset, centerY: bounds.midY, side: side)
            removeButton.label = Strings.removeItem(info.title)
        }
        guard bounds.size != wiggleSize, let layer else { return }
        wiggleSize = bounds.size
        // Neighbors wiggle out of step: the phase comes from the item's place.
        let phase = (frame.minX * 0.37 + frame.minY * 0.61).truncatingRemainder(dividingBy: 1)
        if let wiggle = Motion.sidebar.wiggleAnimation(center: CGPoint(x: bounds.midX, y: bounds.midY), phase: Double(phase)) {
            layer.add(wiggle, forKey: Self.wiggleKey)
        } else {
            layer.removeAnimation(forKey: Self.wiggleKey)
        }
    }

    /// Delete or Forward Delete on a focused item in edit mode takes it out, as its ✕ does; Escape ends edit mode.
    func editingKeyDown(_ event: NSEvent) -> Bool {
        guard isEditing else { return false }
        let key = event.charactersIgnoringModifiers ?? ""
        if key == "\u{1b}" {
            var view = superview
            while let next = view, !(next is SidebarView) { view = next.superview }
            (view as? SidebarView)?.setEditingItems(false)
            return true
        }
        guard let onRemove, ["\u{7f}", "\u{f728}"].contains(key) else { return false }
        onRemove()
        return true
    }
}
