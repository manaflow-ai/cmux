import AppKit
import SwiftUI

// Row hover: an edgeless soft wash on the row under the pointer, the glass
// selection's shape at a lower strength (Aside-style), on workspace rows and
// group headers. Settings > Sidebar > Row Hover (`sidebarRowHover`) turns the
// wash off; hover-revealed chrome (close button, header plus) is unaffected.

extension SidebarWorkspaceRowTableCellView {
    /// Authoritative hover enforcement: the controller sweeps loaded cells
    /// so hover-revealed chrome cannot strand on rows the pointer left
    /// (row-index/id races during churn made per-transition repaints miss).
    func enforcePointerHovering(_ hovering: Bool) {
        // Same hover still repaints: a drag may have held the wash back, or
        // the setting changed.
        guard isPointerHovering != hovering else { return updateHoverFill() }
        isPointerHovering = hovering
        // Full re-apply: hover gates more than the close button (the
        // trailing badge and spinner hide while the close button shows), and
        // re-deriving that subset here would drift from applyModel.
        if let model {
            applyModel(paintedModel(model))
            needsLayout = true
        } else {
            updateCloseVisibility()
        }
    }

    /// Shows the wash when nothing else fills the row: selection,
    /// multi-selection and custom row fills win, and a running reorder drag
    /// shows none. Only touches the wash layer, so it is safe on every
    /// pointer move.
    func updateHoverFill(colorScheme: ColorScheme? = nil) {
        var color: CGColor?
        if isPointerHovering, let model, SidebarGlassSelection.isRowHoverEnabled(),
           !SidebarGlassSelection.isReorderDragRunning(around: self),
           (backgroundView.layer?.backgroundColor?.alpha ?? 0) == 0,
           (backgroundView.layer?.borderWidth ?? 0) == 0 {
            let painted = paintedModel(model)
            if !painted.isActive, !painted.isMultiSelected {
                color = SidebarGlassSelection.hoverFill(
                    for: colorScheme ?? palette(painted).colorScheme
                ).cgColor
            }
        }
        if let color { hoverLayer.backgroundColor = color }
        if hoverLayer.isHidden != (color == nil) { hoverLayer.isHidden = color == nil }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        SidebarGlassSelection.reresolveHoverAfterUnhide(of: self) { [weak self] in self?.updateHoverFill() }
    }
}

/// The header's active and multi-selected paint win over the wash; the plus
/// button's own hover draws on top of it.
extension SidebarGroupHeaderTableCellView {
    /// See the workspace row's `enforcePointerHovering`.
    func enforcePointerHovering(_ hovering: Bool) {
        guard isPointerHovering != hovering else { return updateRowHoverFill() }
        isPointerHovering = hovering
        updatePlusVisibility()
        updateRowHoverFill()
    }

    /// Only touches the wash layer, so it is safe on every pointer move.
    func updateRowHoverFill() {
        var color: CGColor?
        if isPointerHovering, let model, !model.isAnchorActive, !model.isMultiSelected,
           SidebarGlassSelection.isRowHoverEnabled(),
           (backgroundView.layer?.backgroundColor?.alpha ?? 0) == 0,
           (backgroundView.layer?.borderWidth ?? 0) == 0,
           !SidebarGlassSelection.isReorderDragRunning(around: self) {
            color = SidebarGlassSelection.hoverFill(for: model.colorSchemeIsDark ? .dark : .light).cgColor
        }
        if let color { rowHoverLayer.backgroundColor = color }
        rowHoverLayer.cornerRadius = backgroundView.layer?.cornerRadius ?? 4
        if rowHoverLayer.isHidden != (color == nil) { rowHoverLayer.isHidden = color == nil }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        SidebarGlassSelection.reresolveHoverAfterUnhide(of: self) { [weak self] in self?.updateRowHoverFill() }
    }
}

extension SidebarGlassSelection {
    /// Settings > Sidebar > Row Hover. UI-only, on unless turned off.
    static let rowHoverKey = "sidebarRowHover"

    static func isRowHoverEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: rowHoverKey) as? Bool ?? true
    }

    /// The wash layer under a row's content: a sublayer of its fill view, so
    /// it shares the fill's frame, group indent and corners, and the reorder
    /// lift, which copies only the fill view's own paint, never carries it.
    @MainActor
    static func installHoverLayer(_ layer: CALayer, in fillView: NSView) {
        layer.cornerCurve = .continuous
        layer.isHidden = true
        // Hover snaps on and off like the selection; no implicit fades.
        layer.actions = [
            "backgroundColor": NSNull(), "hidden": NSNull(), "bounds": NSNull(),
            "position": NSNull(), "cornerRadius": NSNull(),
        ]
        fillView.layer?.addSublayer(layer)
    }
}

extension UserDefaults {
    /// KVO handle for `SidebarGlassSelection.rowHoverKey`; the property name
    /// must match the key.
    @objc dynamic var sidebarRowHover: Bool {
        object(forKey: SidebarGlassSelection.rowHoverKey) as? Bool ?? true
    }
}
