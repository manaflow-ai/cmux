/// Which page windows host (p03-rendering-050, 056). A hosted page draws through a `CALayerHost` in the cmux
/// window's layer tree, as Chrome's browser window shows GPU output (`ui/accelerated_widget_mac/display_ca_layer_tree.h`).
extension CEFLayerHosting {
    /// The Track A calls (p03-rendering R3) the app makes for a fork's pages.
    /// The default hosts a page window only with all of them (``required``):
    /// without the fence a hosted page shows stale-size frames on each resize,
    /// and without embedder visibility a page window that never orders in reads
    /// as occluded to Chromium and stops drawing.
    nonisolated struct TrackA: OptionSet, Sendable {
        let rawValue: UInt8
        /// Each resize of the page joins its transaction's fence
        /// (`cmux_shim_browser_set_resize_fence`, p03-rendering-043).
        static let resizeFence = TrackA(rawValue: 1 << 0)
        /// The app gives the page window its visibility
        /// (`cmux_browser_set_embedder_visibility`, p03-rendering-058).
        static let embedderVisibility = TrackA(rawValue: 1 << 1)
        static let required: TrackA = [.resizeFence, .embedderVisibility]
    }

    /// Whether a page window hosts, and why not (`debug.cef` `tracker`).
    nonisolated enum Hosting: Equatable, Sendable {
        case hosted
        /// No override and the feature `cefLayerHosting` is off.
        case off
        /// The fork hosts no page window of this kind (``Fork/hostedWidgets``): it keeps its own window.
        case widgetFallback
        /// The app makes not every Track A call for this fork (``TrackA/required``).
        case missingTrackA
    }

    /// The kind of page window over the view. Chrome keeps each of these
    /// pages' views inside the window that shows it: a tab's
    /// `RenderWidgetHostViewCocoa` in its browser window
    /// (`content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm`), a
    /// docked DevTools frontend in the inspected tab's contents
    /// (`chrome/browser/ui/views/frame/contents_layout_manager.cc`), an undocked
    /// one and a popup in a browser window of their own
    /// (`chrome/browser/devtools/devtools_window.cc`, `Browser::TYPE_POPUP` in
    /// `chrome/browser/ui/browser.h`). The fork hosts a pane's page from API 26
    /// and the other kinds from ``CEFLayerHosting/widgetHostingForkAPI``
    /// (``Fork/hostedWidgets``).
    nonisolated enum Widget: String, CaseIterable, Sendable {
        /// A pane's tabs (`CEFPaneHost`).
        case page
        /// An embedded DevTools (`CEFDevToolsController`): docked in the pane or
        /// in cmux's DevTools window, one page window as its view moves.
        case devTools = "devtools"
        /// A popup host's window (`CEFPaneHost.isPopupHost`): a `window.open` popup in the floating popup panel.
        case popup
        /// An extension's popup window (`chrome.windows.create` type popup) attached to a popup host's view
        /// (`CEFPaneHost.attachPopupWindowIfNeeded`).
        case popupWindow = "popup_window"

        /// The kind's key in `debug.cef` `tracker.hosted_pages_by_widget`.
        var name: String { rawValue }
    }

    /// The first fork API whose `cmux_browser_set_layer_hosting` hosts every ``Widget`` kind (per-widget
    /// hosting, p03-rendering-056): a DevTools frontend placed over a cmux view and an attached popup window
    /// too, each with the resize fence and embedder visibility of a pane's page. Below it the fork hosts
    /// only a tab's page window.
    static let widgetHostingForkAPI: Int32 = 35

    /// The kinds of page window fork API `apiVersion` hosts.
    static func widgets(apiVersion: Int32) -> Set<Widget> {
        apiVersion >= widgetHostingForkAPI ? Set(Widget.allCases) : [.page]
    }

    /// Whether the page window hosts. `override` (`browserResize.layerHosting`):
    /// every page window of a fork from ``forkAPI``. Else the feature's default:
    /// a page window of a kind the fork hosts, where the app makes every Track A
    /// call for the fork.
    static func hosting(override: Bool, fork: Fork, widget: Widget) -> Hosting {
        if override { return .hosted }
        guard let trackA = fork.trackA else { return .off }
        guard fork.hostedWidgets.contains(widget) else { return .widgetFallback }
        return trackA.isSuperset(of: .required) ? .hosted : .missingTrackA
    }
}

extension CEFTrackerStats {
    /// Counts why the default left a new page window in its own window.
    mutating func count(_ hosting: CEFLayerHosting.Hosting) {
        switch hosting {
        case .widgetFallback: hostingWidgetFallbacks += 1
        case .missingTrackA: hostingWithoutTrackA += 1
        case .hosted, .off: break
        }
    }

    /// A hosted page view of kind `widget` (nil: a view no ``CEFLayerHosting`` made) entered (`delta` 1)
    /// or left (-1) a window.
    mutating func countHostedPage(widget: String?, delta: Int) {
        hostedPages += delta
        guard let widget else { return }
        let count = (hostedPagesByWidget[widget] ?? 0) + delta
        hostedPagesByWidget[widget] = count == 0 ? nil : count
    }
}
