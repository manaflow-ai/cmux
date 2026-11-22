import AppKit
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSettings

/// `debug.layers`: per window, the child window order (bottom to top) with
/// each window's role, where the overlay plane lives, and whether every app
/// overlay (focus ring, dim, drop highlight) draws above content child
/// windows (Chromium pages). WebKit pages are in-window views and never
/// appear as child windows.
enum DebugLayers {
    static func report(services: AppServices) -> JSONValue {
        let windows = services.windows.controllers.compactMap { controller -> JSONValue? in
            guard let window = controller.window as? ShellWindow else { return nil }
            return report(controller: controller, window: window)
        }
        return .object([
            "windows": .array(windows),
            "consistent": .bool(windows.allSatisfy { $0["consistent"]?.boolValue == true }),
        ])
    }

    private static func report(controller: WindowController, window: ShellWindow) -> JSONValue {
        let layer = window.overlayLayer
        let children = (window.childWindows ?? []).map { child -> JSONValue in
            .object([
                "window_number": .number(Double(child.windowNumber)),
                "role": .string(role(of: child, layer: layer)),
                "class": .string(String(describing: type(of: child))),
                "visible": .bool(child.isVisible),
                "level": .number(Double(child.level.rawValue)),
                "frame": rect(child.frame),
            ])
        }
        let planes = layer.adoptedPlanes.map { plane -> JSONValue in
            let root = plane.home as? LayoutRootView
            return .object([
                "host": .string(plane.isHome ? "root" : (plane.window === layer.overlayPanel ? "overlay_panel" : "other")),
                "in_sync": .bool(plane.isInSync),
                "home_rect_in_window": plane.homeRectInWindow.map(rect) ?? .null,
                "plane_frame": rect(plane.frame),
                "rings": .array((root?.overlayRings ?? []).map { ring in
                    .object(["pane": .string(ring.pane), "frame_in_window": rect(ring.frameInWindow), "shows_ring": .bool(ring.showsRing),
                             "ring_in_window": rect(ring.ringInWindow), "content_in_window": rect(ring.contentInWindow),
                             "ring_in_sync": .bool(ring.ringInWindow == ring.contentInWindow)])
                }),
                "drop_highlight_in_window": root?.dropHighlightFrameInWindow.map(rect) ?? .null,
                "drop_highlight_material": root.map { .string(String(describing: $0.dropHighlightMaterial)) } ?? .null,
            ])
        }
        let pageWindows = WindowOverlayLayer.contentChildWindows(of: window)
        var pagesInSync = true
        let browsers: [JSONValue] = (controller.content?.panes.values.map { $0 } ?? []).compactMap { pane in
            guard case .browser(let entry)? = pane.currentContent else { return nil }
            let content = entry.tab.contentView
            var fields: [String: JSONValue] = [
                "pane": .string(pane.paneKey),
                "engine": .string(String(describing: entry.tab.engineKind)),
                "presentation": .string(entry.tab.presentation == .childWindow ? "child_window" : "in_view"),
                "content_in_window": .bool(content.window === window),
            ]
            if entry.tab.presentation == .childWindow, content.window === window, !content.isHiddenOrHasHiddenAncestor {
                // The page window must cover the host view exactly, in
                // screen coordinates, whatever moved the window.
                let host = window.convertToScreen(content.convert(content.bounds, to: nil))
                let page = pageWindows.min { distance($0.frame, host) < distance($1.frame, host) }
                let synced = page.map { distance($0.frame, host) <= 1 } ?? false
                if !synced { pagesInSync = false }
                fields["host_screen_rect"] = rect(host)
                fields["page_window_frame"] = page.map { rect($0.frame) } ?? .null
                fields["page_in_sync"] = .bool(synced)
            }
            return .object(fields)
        }
        let above = layer.isOverlayAboveContent
        let inSync = layer.adoptedPlanes.allSatisfy(\.isInSync)
        // Every displayed ring strokes its pane's rounded content rect.
        let ringsInSync = layer.adoptedPlanes.allSatisfy { plane in
            ((plane.home as? LayoutRootView)?.overlayRings ?? []).allSatisfy { $0.ringInWindow == $0.contentInWindow }
        }
        var fields: [String: JSONValue] = [:]
        #if DEBUG
        fields["ring_layout_passes"] = .number(Double(layer.ringLayoutPasses))
        fields["ring_lag_passes"] = .number(Double(layer.ringLagPasses))
        fields["last_ring_lag"] = layer.lastRingLag.map(JSONValue.string) ?? .null
        #endif
        let base: [String: JSONValue] = [
            "id": .string(controller.state.id),
            "window_number": .number(Double(window.windowNumber)),
            "frame": rect(window.frame),
            "placement": .string(layer.placement.rawValue),
            "overlay_panel": layer.overlayPanel.map { .number(Double($0.windowNumber)) } ?? .null,
            "overlay_panel_frame": layer.overlayPanel.map { rect($0.frame) } ?? .null,
            "child_windows": .array(children),
            "overlay_above_content": .bool(above),
            "planes": .array(planes),
            "browsers": .array(browsers),
            "interactive_rects_in_window": .array(layer.interactiveRects.map(rect)),
            "divider_areas_in_window": .array(layer.dividerAreas.map { rect($0.rect) }),
            "divider_catchers_in_window": .array(layer.catchers.framesInWindow.sorted { $0.key < $1.key }.map { rect($0.value) }),
            "reorders": .number(Double(layer.reorderCount)),
            "child_window_violations": .array(ChildWindowPolicy.violations.map(JSONValue.string)),
            "pages_in_sync": .bool(pagesInSync),
            "rings_in_sync": .bool(ringsInSync),
            "consistent": .bool(above && inSync && pagesInSync && ringsInSync),
        ]
        return .object(fields.merging(base) { _, new in new })
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }

    #if DEBUG
    /// `debug.window_frame` (DEBUG builds): sets a window's frame the way an
    /// Accessibility client (Rectangle) or a display change does: one
    /// programmatic `setFrame`, no live resize. `frame` is [x, y, w, h] in
    /// screen points (AppKit, bottom-left origin); or `screen` (index into
    /// `NSScreen.screens`, or "last") keeps the size and centers it there.
    static func setWindowFrame(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let windowID = params["window"]?.stringValue
        guard let window = services.windows.controllers.first(where: { windowID == nil || $0.state.id == windowID })?.window else {
            return .object(["error": .string("no window")])
        }
        var target = window.frame
        if let values = params["frame"]?.arrayValue?.compactMap(\.doubleValue), values.count == 4 {
            target = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        } else if let screenParam = params["screen"] {
            let screens = NSScreen.screens
            let index = screenParam.stringValue == "last" ? screens.count - 1 : (screenParam.intValue ?? 0)
            guard screens.indices.contains(index) else { return .object(["error": .string("no such screen")]) }
            let visible = screens[index].visibleFrame
            target.origin = CGPoint(x: visible.midX - target.width / 2, y: visible.midY - target.height / 2)
        }
        window.setFrame(target, display: true)
        return .object(["frame": rect(window.frame), "screen": .string(window.screen?.localizedName ?? "")])
    }

    /// `debug.drop_highlight` (DEBUG builds): drives the layout's in-process
    /// tab drag API (the one `TabDropTargets` calls on every drag move) at
    /// `pane`'s point `at` ([fx, fy] fractions, default center), so the drop
    /// zone shows over that pane without moving the user's pointer.
    /// `"end": true` cancels it.
    static func dropHighlight(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let windowID = params["window"]?.stringValue
        guard let controller = services.windows.controllers.first(where: { windowID == nil || $0.state.id == windowID }),
              let layout = controller.content?.layoutView else { return .object(["error": .string("no window")]) }
        let tab = LayoutTabID("debug-drop-highlight")
        // "material": "liquidGlass" | "vibrancy" | "opaque" pins it; "auto" follows this Mac.
        if let name = params["material"]?.stringValue {
            let pinned: [String: OverlayMaterial] = ["liquidGlass": .liquidGlass, "vibrancy": .vibrancy, "opaque": .opaque]
            layout.pinDropHighlightMaterial(pinned[name])
        }
        if params["end"]?.boolValue == true {
            layout.cancelTabDrag()
            return .object(["ended": .bool(true)])
        }
        guard let pane = params["pane"]?.stringValue ?? controller.focus.state.pane,
              let frame = layout.frame(of: LayoutPaneID(pane)) else { return .object(["error": .string("no pane")]) }
        let fractions = params["at"]?.arrayValue?.compactMap(\.doubleValue) ?? [0.5, 0.5]
        let local = CGPoint(x: frame.minX + frame.width * (fractions.first ?? 0.5), y: frame.minY + frame.height * (fractions.last ?? 0.5))
        let target = layout.updateTabDrag(tab, locationInWindow: layout.convert(local, to: nil))
        return .object(["target": target.map { .string(String(describing: $0)) } ?? .null,
                        "material": .string(String(describing: layout.dropHighlightMaterial)),
                        "highlight_in_window": layout.dropHighlightFrameInWindow.map(rect) ?? .null])
    }
    #endif

    private static func role(of child: NSWindow, layer: WindowOverlayLayer) -> String {
        if child === layer.overlayPanel { return "overlay" }
        if WindowOverlayLayer.isContent(child) { return "content" }
        return "panel"
    }

    private static func rect(_ rect: CGRect) -> JSONValue {
        .array([rect.minX, rect.minY, rect.width, rect.height].map { .number(Double($0)) })
    }
}
