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
        var scheme: ColorScheme?
        if isPointerHovering, let model, SidebarGlassSelection.isRowHoverEnabled(),
           !SidebarGlassSelection.isReorderDragRunning(around: self),
           (backgroundView.layer?.backgroundColor?.alpha ?? 0) == 0,
           (backgroundView.layer?.borderWidth ?? 0) == 0 {
            let painted = paintedModel(model)
            if !painted.isActive, !painted.isMultiSelected {
                scheme = colorScheme ?? palette(painted).colorScheme
            }
        }
        if let scheme { SidebarGlassSelection.paintHover(hoverLayer, for: scheme) }
        if hoverLayer.isHidden != (scheme == nil) { hoverLayer.isHidden = scheme == nil }
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
        var scheme: ColorScheme?
        if isPointerHovering, let model, !model.isAnchorActive, !model.isMultiSelected,
           SidebarGlassSelection.isRowHoverEnabled(),
           (backgroundView.layer?.backgroundColor?.alpha ?? 0) == 0,
           (backgroundView.layer?.borderWidth ?? 0) == 0,
           !SidebarGlassSelection.isReorderDragRunning(around: self) {
            scheme = model.colorSchemeIsDark ? .dark : .light
        }
        if let scheme { SidebarGlassSelection.paintHover(rowHoverLayer, for: scheme) }
        rowHoverLayer.cornerRadius = backgroundView.layer?.cornerRadius ?? 4
        if rowHoverLayer.isHidden != (scheme == nil) { rowHoverLayer.isHidden = scheme == nil }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        SidebarGlassSelection.reresolveHoverAfterUnhide(of: self) { [weak self] in self?.updateRowHoverFill() }
    }
}

extension SidebarGlassSelection {
    /// Paints a row's hover wash. The stock light look gets a glass wash,
    /// layers only: a white fill a touch brighter at the top and a 0.5 pt
    /// white inner rim like the selection's glass edge. Tunable through
    /// `sidebarRowHoverFillOpacityLight` (mid fill, default 48%),
    /// `sidebarRowHoverGradientLight` (top-to-bottom spread, default 10%) and
    /// `sidebarRowHoverRimLight` (rim, default 55%). Elsewhere a flat fill.
    @MainActor
    static func paintHover(_ layer: CAGradientLayer, for colorScheme: ColorScheme, defaults: UserDefaults = .standard) {
        guard usesStockLightLook(colorScheme, defaults: defaults) else {
            layer.colors = nil
            layer.borderWidth = 0
            layer.backgroundColor = hoverFill(for: colorScheme, defaults: defaults).cgColor
            return
        }
        func value(_ key: String, _ fallback: Double) -> CGFloat { CGFloat(defaults.object(forKey: key) as? Double ?? fallback) }
        let mid = value("sidebarRowHoverFillOpacityLight", 0.48)
        let spread = value("sidebarRowHoverGradientLight", 0.1)
        layer.backgroundColor = nil
        // Unflipped layer space: y = 1 is the top.
        layer.startPoint = CGPoint(x: 0.5, y: 1)
        layer.endPoint = CGPoint(x: 0.5, y: 0)
        layer.colors = [NSColor.white.withAlphaComponent(mid + spread / 2).cgColor,
                        NSColor.white.withAlphaComponent(max(0, mid - spread / 2)).cgColor]
        layer.borderWidth = 0.5
        layer.borderColor = NSColor.white.withAlphaComponent(value("sidebarRowHoverRimLight", 0.55)).cgColor
    }

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
            "position": NSNull(), "cornerRadius": NSNull(), "colors": NSNull(),
            "borderColor": NSNull(), "borderWidth": NSNull(),
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
