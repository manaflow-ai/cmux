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

    /// Paints the wash layer: the selection glass on the stock light pill,
    /// else the hover wash when nothing else fills the row (selection,
    /// multi-selection and custom row fills win, and a running reorder drag
    /// shows none). Only touches the fill view's layers, so it is safe on
    /// every pointer move.
    func updateHoverFill(colorScheme: ColorScheme? = nil) {
        var hovering = false
        if isPointerHovering, let model, SidebarGlassSelection.isRowHoverEnabled(),
           !SidebarGlassSelection.isReorderDragRunning(around: self),
           (backgroundView.layer?.backgroundColor?.alpha ?? 0) == 0,
           (backgroundView.layer?.borderWidth ?? 0) == 0 {
            let painted = paintedModel(model)
            hovering = !painted.isActive && !painted.isMultiSelected
        }
        let scheme = colorScheme ?? (model?.colorSchemeIsDark == true ? .dark : .light)
        SidebarGlassSelection.paintOverlay(hoverLayer, in: backgroundView, for: scheme, hovering: hovering)
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

    /// Selection glass or hover wash, as on workspace rows. Only touches the
    /// fill view's layers, so it is safe on every pointer move.
    func updateRowHoverFill() {
        let hovering = isPointerHovering && model.map { !$0.isAnchorActive && !$0.isMultiSelected } == true
            && SidebarGlassSelection.isRowHoverEnabled()
            && (backgroundView.layer?.backgroundColor?.alpha ?? 0) == 0
            && (backgroundView.layer?.borderWidth ?? 0) == 0
            && !SidebarGlassSelection.isReorderDragRunning(around: self)
        let scheme: ColorScheme = model?.colorSchemeIsDark == true ? .dark : .light
        SidebarGlassSelection.paintOverlay(rowHoverLayer, in: backgroundView, for: scheme, hovering: hovering)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        SidebarGlassSelection.reresolveHoverAfterUnhide(of: self) { [weak self] in self?.updateRowHoverFill() }
    }
}

extension SidebarGlassSelection {
    /// Paints a cell's wash layer (a sublayer of its fill view): the
    /// selection glass while the fill view wears the stock light pill, else
    /// the hover wash while `hovering`, else nothing. Owns the pill's edge
    /// width and shadow, and keeps the layer fitted inside the fill view's
    /// edge, so every selection paint path (row, header, optimistic press)
    /// gets the glass by painting the pill's base fill.
    @MainActor
    static func paintOverlay(
        _ layer: CAGradientLayer, in fillView: NSView, for colorScheme: ColorScheme,
        hovering: Bool, defaults: UserDefaults = .standard
    ) {
        let glass = wearsLightPill(fillView.layer, for: colorScheme, defaults: defaults)
        if glass, let fill = fillView.layer {
            let edge = edge(for: colorScheme, defaults: defaults)
            fill.borderWidth = edge.alphaComponent > 0 ? 0.5 : 0
            fill.borderColor = edge.cgColor
            paintSelectionGlass(layer, defaults: defaults)
        } else if hovering {
            paintHover(layer, for: colorScheme, defaults: defaults)
        }
        applySelectionShadow(to: fillView, glass, defaults: defaults)
        fitOverlay(layer)
        if layer.isHidden != !(glass || hovering) { layer.isHidden = !(glass || hovering) }
    }

    /// True when `fill` is painted with the stock light pill's base, the
    /// active row and active group header look (multi-selection and custom
    /// selection colours paint other fills).
    static func wearsLightPill(_ fill: CALayer?, for colorScheme: ColorScheme, defaults: UserDefaults = .standard) -> Bool {
        isLightPill(fill?.backgroundColor, for: colorScheme, defaults: defaults)
    }

    /// True when `color` is the stock light pill's base fill.
    static func isLightPill(_ color: CGColor?, for colorScheme: ColorScheme, defaults: UserDefaults = .standard) -> Bool {
        guard let color, usesStockLightLook(colorScheme, defaults: defaults) else { return false }
        return color == fill(for: colorScheme, defaults: defaults).cgColor
    }

    /// The stock light pill's glass, over the fill view's base (white at the
    /// pill's bottom alpha): a gradient that lifts the top to the pill's top
    /// alpha, and a bright inner rim (`sidebarSelectionRimLight`, default
    /// 80%), stronger than the hover's.
    @MainActor
    static func paintSelectionGlass(_ layer: CAGradientLayer, defaults: UserDefaults = .standard) {
        let pill = lightPill(defaults)
        // White over white composites to 1 - (1 - a)(1 - b).
        let lift = 1 - (1 - pill.top) / max(0.001, 1 - pill.bottom)
        let rim = defaults.object(forKey: "sidebarSelectionRimLight") as? Double ?? 0.8
        paintGlass(layer, top: lift, bottom: 0, rim: CGFloat(rim))
    }

    /// Insets a wash layer inside its fill view's border, so the selection
    /// rim sits just inside the pill's outer edge rather than under it.
    static func fitOverlay(_ layer: CALayer) {
        guard let fill = layer.superlayer else { return }
        let inset = fill.borderWidth
        let frame = fill.bounds.insetBy(dx: inset, dy: inset)
        if layer.frame != frame { layer.frame = frame }
        layer.cornerRadius = max(0, fill.cornerRadius - inset)
    }

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
        paintGlass(layer, top: mid + spread / 2, bottom: mid - spread / 2, rim: value("sidebarRowHoverRimLight", 0.55))
    }

    /// White glass, layers only: a top-to-bottom white gradient and a 0.5 pt
    /// white inner rim.
    @MainActor
    private static func paintGlass(_ layer: CAGradientLayer, top: CGFloat, bottom: CGFloat, rim: CGFloat) {
        layer.backgroundColor = nil
        // Unflipped layer space: y = 1 is the top.
        layer.startPoint = CGPoint(x: 0.5, y: 1)
        layer.endPoint = CGPoint(x: 0.5, y: 0)
        layer.colors = [NSColor.white.withAlphaComponent(top).cgColor,
                        NSColor.white.withAlphaComponent(max(0, bottom)).cgColor]
        layer.borderWidth = 0.5
        layer.borderColor = NSColor.white.withAlphaComponent(rim).cgColor
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

extension SidebarRowPalette {
    /// True while the active row wears the stock light glass pill. Text
    /// then takes one colour on every row: titles are the pill's near-black
    /// on all rows and secondary lines keep their resting colour on the
    /// pill, so the pill alone marks the active row.
    var usesLightPillText: Bool {
        SidebarGlassSelection.isLightPill(selectedBackground.cgColor, for: colorScheme)
    }

    /// Whether secondary lines take the selected foreground.
    var usesSelectedText: Bool { model.isActive && !usesLightPillText }
}
