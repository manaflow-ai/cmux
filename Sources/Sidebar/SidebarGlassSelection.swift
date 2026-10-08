import AppKit
import SwiftUI

/// The sidebar's glass selection: a neutral translucent patch of the glass
/// with a hairline edge, never the accent colour (Aside-style). Fill and edge
/// strength can be tuned with the `sidebarGlassSelectionFillOpacity` and
/// `sidebarGlassSelectionEdgeOpacity` defaults. The hover wash on an
/// unselected row is the same patch, softer and without the edge
/// (`sidebarRowHoverFillOpacity`, `sidebarRowHoverFillOpacityLight`).
enum SidebarGlassSelection {
    static func fill(for colorScheme: ColorScheme, defaults: UserDefaults = .standard) -> NSColor {
        SidebarAppearanceColorResolver().resolvedColor(
            .labelColor,
            for: colorScheme,
            opacity: defaults.object(forKey: "sidebarGlassSelectionFillOpacity") as? Double
                ?? (colorScheme == .dark ? 0.13 : 0.07)
        )
    }

    static func edge(for colorScheme: ColorScheme, defaults: UserDefaults = .standard) -> NSColor {
        SidebarAppearanceColorResolver().resolvedColor(
            .labelColor,
            for: colorScheme,
            opacity: defaults.object(forKey: "sidebarGlassSelectionEdgeOpacity") as? Double
                ?? (colorScheme == .dark ? 0.14 : 0.12)
        )
    }

    /// Fill for the row under the pointer. Separate dark and light keys, since
    /// the same alpha reads much stronger as a black wash on light glass.
    static func hoverFill(for colorScheme: ColorScheme, defaults: UserDefaults = .standard) -> NSColor {
        let isDark = colorScheme == .dark
        return SidebarAppearanceColorResolver().resolvedColor(
            .labelColor,
            for: colorScheme,
            opacity: defaults.object(forKey: isDark ? "sidebarRowHoverFillOpacity" : "sidebarRowHoverFillOpacityLight") as? Double
                ?? (isDark ? 0.05 : 0.035)
        )
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
