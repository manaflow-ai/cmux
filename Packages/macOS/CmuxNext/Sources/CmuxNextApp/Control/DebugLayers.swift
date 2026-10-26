import AppKit
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSettings

/// `debug.layers`: per window, the child window order (bottom to top) with
/// each window's role, where the overlay plane lives, and whether every app
/// overlay (focus ring, dim, drop highlight) draws above content child
/// windows (Chromium pages). WebKit pages are in-window views and never
/// appear as child windows. `titlebar_band: true` adds `NSWindow.titlebarBandMap`.
/// Each shown Chromium page counts the `CALayerHost` layers (the class Chromium shows its
/// GPU output with) in three trees: the pane's own (`hosted_layer_hosts`: only the app's
/// `CEFHostedPageView` host, so it proves nothing about the fork), the context that host shows
/// (`hosted_context_layer_hosts`: the hosted `CAContext` lives in this process, so its layers are
/// readable; null when the pane shows no context or QuartzCore has no `allContexts`), and the
/// page window's (`page_window_layer_hosts`). A page the fork really hosts has >= 1 in the hosted
/// context (Chromium's GPU output, there once Chromium drew) and 0 in its page window.
enum DebugLayers {
    static func report(services: AppServices, params: [String: JSONValue] = [:]) -> JSONValue {
        let windows = services.windows.controllers.compactMap { controller -> JSONValue? in
            guard let window = controller.window as? ShellWindow else { return nil }
            return report(controller: controller, window: window)
        }
        let band = params["titlebar_band"]?.boolValue == true ? services.windows.controllers.first?.window?.titlebarBandMap() : nil
        return .object([
            "windows": .array(windows),
            "consistent": .bool(windows.allSatisfy { $0["consistent"]?.boolValue == true }),
            "layout_passes": layoutPasses(),
        ].merging(band.flatMap { JSONValue(foundation: $0) }.map { ["titlebar_band": $0] } ?? [:]) { $1 })
    }

    /// `LayoutPassGuard`: the most layout calls one view had in one
    /// window layout (one `layoutIfNeeded`), the loops it caught (view class, window, ancestry)
    /// and the busiest view classes since launch or the last reset.
    static func layoutPasses() -> JSONValue {
        let guardian = LayoutPassGuard.shared
        return .object([
            "installed": .bool(guardian.isInstalled),
            "bound": .number(Double(LayoutPassGuard.bound)),
            "max_in_one_turn": .number(Double(guardian.maxPassesInOneTurn)),
            "max_view_class": guardian.maxPassesClass.map(JSONValue.string) ?? .null,
            "max_window_class": guardian.maxPassesWindowClass.map(JSONValue.string) ?? .null,
            // The limit of that window (LayoutPassGuard.limit(viewCount:)); `bound` is the largest.
            "max_window_limit": guardian.maxPassesWindowLimit.map { .number(Double($0)) } ?? .null,
            "loops": .array(guardian.reports.map { report in
                .object([
                    "view_class": .string(report.viewClass),
                    "window_class": report.windowClass.map(JSONValue.string) ?? .null,
                    "ancestry": .array(report.ancestry.map(JSONValue.string)),
                    "passes": .number(Double(report.passes)),
                    "limit": .number(Double(report.limit)),
                ])
            }),
            "top_classes": .array(guardian.passesByClass.prefix(20).map { entry in
                .object(["view_class": .string(entry.viewClass), "passes": .number(Double(entry.passes))])
            }),
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
                "layout_pass_limit": .number(Double(LayoutPassGuard.limit(viewCount: LayoutPassGuard.viewCount(of: child)))),
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
                             "ring_in_sync": .bool(ring.ringInSync)])
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
                fields["hosted_layer_hosts"] = .number(Double(layerHostCount(content.layer)))
                fields["hosted_context_layer_hosts"] = hostedContextLayerHostCount(content.layer).map { .number(Double($0)) } ?? .null
                fields["page_window_layer_hosts"] = page.map { .number(Double(layerHostCount($0.contentView?.layer))) } ?? .null
            }
            return .object(fields)
        }
        let above = layer.isOverlayAboveContent
        let inSync = layer.adoptedPlanes.allSatisfy(\.isInSync)
        // Every displayed ring strokes its pane's rounded content rect.
        let ringsInSync = layer.adoptedPlanes.allSatisfy { plane in
            ((plane.home as? LayoutRootView)?.overlayRings ?? []).allSatisfy { $0.ringInSync }
        }
        var fields: [String: JSONValue] = [:]
        // The window's screen less the menu bar and Dock, and the whole screen (screen points, null
        // on no screen): a caller checks that the window lies on its screen below the menu bar.
        fields["screen_visible_frame"] = window.screen.map { rect($0.visibleFrame) } ?? .null
        fields["screen_frame"] = window.screen.map { rect($0.frame) } ?? .null
        #if DEBUG || CMUX_BENCH_HOOKS
        fields["ring_layout_passes"] = .number(Double(layer.ringLayoutPasses))
        fields["ring_lag_passes"] = .number(Double(layer.ringLagPasses))
        fields["last_ring_lag"] = layer.lastRingLag.map(JSONValue.string) ?? .null
        #endif
        let base: [String: JSONValue] = [
            "id": .string(controller.state.id),
            "window_number": .number(Double(window.windowNumber)),
            "frame": rect(window.frame),
            // Layout calls of one view in one window layout the guard allows in this window.
            "layout_pass_limit": .number(Double(LayoutPassGuard.limit(viewCount: LayoutPassGuard.viewCount(of: window)))),
            "placement": .string(layer.placement.rawValue),
            "overlay_panel": layer.overlayPanel.map { .number(Double($0.windowNumber)) } ?? .null,
            "overlay_panel_frame": layer.overlayPanel.map { rect($0.frame) } ?? .null,
            "child_windows": .array(children),
            "overlay_above_content": .bool(above),
            "planes": .array(planes),
            "browsers": .array(browsers),
            "interactive_rects_in_window": .array(layer.interactiveRects.map(rect)),
            "divider_areas_in_window": .array(layer.dividerAreas.map { rect($0.rect) }),
            "sidebar_resize_area_in_window": layer.sidebarResizeArea.map { rect($0.rect) } ?? .null,
            "divider_catchers_in_window": .array(layer.catchers.framesInWindow.sorted { $0.key < $1.key }.map { rect($0.value) }),
            "divider_catcher_updates": .number(Double(layer.catchers.panelUpdates)),
            "reorders": .number(Double(layer.reorderCount)),
            "child_window_violations": .array(ChildWindowPolicy.violations.map(JSONValue.string)),
            "pages_in_sync": .bool(pagesInSync),
            "rings_in_sync": .bool(ringsInSync),
            "consistent": .bool(above && inSync && pagesInSync && ringsInSync),
        ]
        return .object(fields.merging(base) { _, new in new })
    }

    /// `CALayerHost` layers in `layer`'s tree (a remote context's layers never show in-process).
    private static func layerHostCount(_ layer: CALayer?) -> Int {
        guard let layer else { return 0 }
        let own = NSStringFromClass(type(of: layer)) == "CALayerHost" ? 1 : 0
        return own + (layer.sublayers ?? []).reduce(0) { $0 + layerHostCount($1) }
    }

    /// `CALayerHost` layers in the context the first `CALayerHost` under `layer` shows (the pane's
    /// `CEFHostedPageView`); nil without one, or when that context is not in this process. Every
    /// QuartzCore SPI message (``QuartzLayerHostingSPI``) is sent only after `responds(to:)` proved the
    /// receiver implements it, so an OS without it gives nil, never an unrecognized selector.
    private static func hostedContextLayerHostCount(_ layer: CALayer?) -> Int? {
        let contextIdGetter = #selector(getter: QuartzLayerHostingSPI.contextId)
        let rootLayerGetter = #selector(getter: QuartzLayerHostingSPI.layer)
        guard let host = firstLayerHost(layer), host.responds(to: contextIdGetter) else { return nil }
        let id = unsafeBitCast(host, to: QuartzLayerHostingSPI.self).contextId
        guard id != 0, let contextClass: AnyClass = NSClassFromString("CAContext"),
              (contextClass as AnyObject).responds(to: #selector(QuartzLayerHostingSPI.allContexts)),
              let contexts = (contextClass as AnyObject).perform(#selector(QuartzLayerHostingSPI.allContexts))?
                  .takeUnretainedValue() as? [NSObject] else { return nil }
        for context in contexts {
            // Two checks, not one `&&`: its autoclosure would capture the non-Sendable context.
            guard context.responds(to: contextIdGetter) else { continue }
            guard context.responds(to: rootLayerGetter) else { continue }
            let spi = unsafeBitCast(context, to: QuartzLayerHostingSPI.self)
            guard spi.contextId == id else { continue }
            return layerHostCount(spi.layer)
        }
        return nil
    }

    private static func firstLayerHost(_ layer: CALayer?) -> CALayer? {
        guard let layer else { return nil }
        if NSStringFromClass(type(of: layer)) == "CALayerHost" { return layer }
        return (layer.sublayers ?? []).lazy.compactMap { firstLayerHost($0) }.first
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }

    #if DEBUG || CMUX_BENCH_HOOKS
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
        // `visible_frame`: the window's screen less the menu bar and Dock; `screen_frame`: the whole
        // screen (screen points, null on no screen). A caller places the window on its screen with them
        // and checks that it lies there.
        let visible: JSONValue = window.screen.map { rect($0.visibleFrame) } ?? .null
        let whole: JSONValue = window.screen.map { rect($0.frame) } ?? .null
        return .object(["frame": rect(window.frame), "screen": .string(window.screen?.localizedName ?? ""),
                        "visible_frame": visible, "screen_frame": whole])
    }

    /// `debug.drop_highlight` (DEBUG builds): drives the layout's in-process
    /// tab drag API (the one `TabDropTargets` calls on every drag move) at
    /// `pane`'s point `at` ([fx, fy] fractions, default center), so the drop
    /// zone shows over that pane without moving the user's pointer.
    /// `"end": true` cancels it; `"report": true` only reads its state.
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
        // `"report": true` reads the overlay without driving it: after a real
        // drop the ring must be gone and stay gone (cx-ohle).
        if params["report"]?.boolValue == true {
            return .object(["showing": .bool(layout.dropHighlightShowing),
                            "ring_opacity": layout.dropRingOpacity.map { .number(Double($0)) } ?? .null,
                            "style": .string(String(describing: layout.dropHighlightStyle))])
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

/// The QuartzCore SPI `debug.layers` reads: `+[CAContext allContexts]`, `-[CAContext contextId]`,
/// `-[CAContext layer]` and `-[CALayerHost contextId]`. No class conforms; a caller casts an object
/// it asked `responds(to:)` for the one message it sends.
@objc private protocol QuartzLayerHostingSPI {
    /// `+[CAContext allContexts]`: declared as an instance requirement because `#selector` cannot name a static
    /// one of a protocol; it is sent to the class object with `perform(_:)`.
    func allContexts() -> [NSObject]?
    var contextId: UInt32 { get }
    var layer: CALayer? { get }
}
