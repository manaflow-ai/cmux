import AppKit
import SwiftUI

/// The sidebar's glass selection: a neutral translucent patch of the glass
/// with a hairline edge, never the accent colour (Aside-style). Fill and edge
/// strength can be tuned with the `sidebarGlassSelectionFillOpacity` and
/// `sidebarGlassSelectionEdgeOpacity` defaults. The hover wash on an
/// unselected row is the same patch, softer and without the edge
/// (`sidebarRowHoverFillOpacity`, `sidebarRowHoverFillOpacityLight`).
enum SidebarGlassSelection {
    /// Light mode on the stock tint takes Aside's light look: a white glass
    /// pill (see `paintSelectionGlass`), a fainter glass hover wash, and dark
    /// gray row titles (black at 69%, ~#414141 on the ground) instead of
    /// near-black.
    /// It owns its values: the opacity tuning keys below shape the
    /// translucent patch, which it does not use.
    /// A chosen tint, a light-mode tint or matching the terminal opts out.
    static func usesStockLightLook(_ colorScheme: ColorScheme, defaults: UserDefaults = .standard) -> Bool {
        guard colorScheme == .light, defaults.string(forKey: "sidebarTintHexLight") == nil,
              !(defaults.object(forKey: "sidebarMatchTerminalBackground") as? Bool ?? false) else { return false }
        let stock = SidebarTintDefaults().hex
        return (defaults.string(forKey: "sidebarTintHex") ?? stock).caseInsensitiveCompare(stock) == .orderedSame
    }

    static func fill(for colorScheme: ColorScheme, defaults: UserDefaults = .standard) -> NSColor {
        // The pill's base, white at its gradient's bottom (66%); the glass
        // overlay brightens the top.
        if usesStockLightLook(colorScheme, defaults: defaults) { return NSColor.white.withAlphaComponent(lightPill(defaults).bottom) }
        return SidebarAppearanceColorResolver().resolvedColor(
            .labelColor,
            for: colorScheme,
            opacity: defaults.object(forKey: "sidebarGlassSelectionFillOpacity") as? Double
                ?? (colorScheme == .dark ? 0.13 : 0.07)
        )
    }

    /// The stock light pill's white at its top and bottom: a mid strength
    /// (`sidebarSelectionFillOpacityLight`, default 74%) spread by the
    /// top-to-bottom gradient (`sidebarSelectionGradientLight`, default 16%).
    static func lightPill(_ defaults: UserDefaults = .standard) -> (top: CGFloat, bottom: CGFloat) {
        let mid = defaults.object(forKey: "sidebarSelectionFillOpacityLight") as? Double ?? 0.74
        let spread = defaults.object(forKey: "sidebarSelectionGradientLight") as? Double ?? 0.16
        return (CGFloat(min(1, mid + spread / 2)), CGFloat(max(0, mid - spread / 2)))
    }

    static func edge(for colorScheme: ColorScheme, defaults: UserDefaults = .standard) -> NSColor {
        if usesStockLightLook(colorScheme, defaults: defaults) {
            return NSColor.black.withAlphaComponent(defaults.object(forKey: "sidebarSelectionEdgeOpacityLight") as? Double ?? 0.08)
        }
        return SidebarAppearanceColorResolver().resolvedColor(
            .labelColor,
            for: colorScheme,
            opacity: defaults.object(forKey: "sidebarGlassSelectionEdgeOpacity") as? Double
                ?? (colorScheme == .dark ? 0.14 : 0.12)
        )
    }

    /// Fill for the row under the pointer. Separate dark and light keys, since
    /// the same alpha reads much stronger as a black wash on light glass. In
    /// the stock light look the light key is the strength of a white wash
    /// between the gray ground and the white pill (default 62%); elsewhere it
    /// is a black wash, capped so a white-wash value cannot turn heavy.
    static func hoverFill(for colorScheme: ColorScheme, defaults: UserDefaults = .standard) -> NSColor {
        let isDark = colorScheme == .dark
        let stored = defaults.object(forKey: isDark ? "sidebarRowHoverFillOpacity" : "sidebarRowHoverFillOpacityLight") as? Double
        if usesStockLightLook(colorScheme, defaults: defaults) {
            return NSColor.white.withAlphaComponent(stored ?? 0.62)
        }
        return SidebarAppearanceColorResolver().resolvedColor(
            .labelColor,
            for: colorScheme,
            opacity: min(stored ?? (isDark ? 0.05 : 0.035), 0.2)
        )
    }

    /// The light look's pill sits on a barely-there 1 pt drop shadow
    /// (`sidebarSelectionShadowOpacityLight`, default 5%). Set through the
    /// view: AppKit owns a layer-backed view's layer shadow.
    @MainActor
    static func applySelectionShadow(to view: NSView, _ on: Bool, defaults: UserDefaults = .standard) {
        let opacity = on ? (defaults.object(forKey: "sidebarSelectionShadowOpacityLight") as? Double ?? 0.05) : 0
        guard abs((view.shadow?.shadowColor?.alphaComponent ?? 0) - opacity) > 0.001 else { return }
        guard opacity > 0 else { view.shadow = nil; return }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(opacity)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 1.5
        view.shadow = shadow
    }

    /// True while a reorder drag carries rows in the sidebar holding `view`.
    /// Autoscroll moves rows under the pointer mid-drag and the controller
    /// re-resolves hover then, but no row should light up until the button
    /// is released.
    @MainActor
    static func isReorderDragRunning(around view: NSView) -> Bool {
        guard NSEvent.pressedMouseButtons != 0 else { return false }
        return sidebarTable(around: view)?.reorderPinnedRowsRect != nil
    }

    /// A reorder lift hides the dragged rows' cells and unhides them when the
    /// drag ends, possibly with the pointer far away and no exit event
    /// delivered (tracking areas stop during a drag session). Re-resolves
    /// hover from the live pointer once that teardown finishes, so it cannot
    /// strand. Also covers the sidebar being shown again.
    @MainActor
    static func reresolveHoverAfterUnhide(of view: NSView, then repaint: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { [weak view] in
            guard let view, !view.isHiddenOrHasHiddenAncestor else { return }
            sidebarTable(around: view)?.workspaceController?.recomputeHoveredRow()
            repaint()
        }
    }

    @MainActor
    private static func sidebarTable(around view: NSView) -> SidebarWorkspaceTableViewImpl? {
        var current = view.superview
        while let candidate = current, !(candidate is NSTableView) { current = candidate.superview }
        return current as? SidebarWorkspaceTableViewImpl
    }

    /// Text on a translucent selection. The patch is a tint on the pane, not
    /// a surface, so text keeps the pane's own label colour, which the patch's
    /// hue encodes (white patch on dark glass, black patch on light). Nil for
    /// an opaque selection, which picks its foreground by contrast instead.
    static func foreground(on backgroundColor: NSColor, opacity: CGFloat) -> NSColor? {
        guard backgroundColor.alphaComponent < 0.5 else { return nil }
        let brightness = backgroundColor.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 1
        return (brightness > 0.5 ? NSColor.white : NSColor.black).withAlphaComponent(opacity)
    }
}
