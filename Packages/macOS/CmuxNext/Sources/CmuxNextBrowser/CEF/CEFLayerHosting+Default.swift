/// Which page windows host (p03-rendering-050). A hosted page draws through a `CALayerHost` in the cmux
/// window's layer tree, as Chrome's browser window shows GPU output (`ui/accelerated_widget_mac/display_ca_layer_tree.h`).
extension CEFLayerHosting {
    /// The Track A calls (p03-rendering R3) the app makes for a fork's pages.
    /// The default hosts a pane's page only with all of them (``required``):
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

    /// The last `CEFEngine`'s page features (`CEFRuntime.pageHosting`), read by each new page window's ``Fork``.
    nonisolated struct Policy: Equatable, Sendable {
        /// Feature `cefLayerHosting`: nil while off, else the Track A calls the app makes.
        var trackA: TrackA?
        /// Feature `cefAttachedPages`: a pane's tabs attach Chromium's own view where the fork can (Track B).
        var attachesViews = false
        /// Feature `cefLayerHostingEveryPage` (DEBUG and bench builds, the benches' on arm): every page window
        /// hosts, whatever its widget and Track A calls.
        var hostsEveryPage = false
    }

    /// Whether the tabs of this page window attach Chromium's view (``CEFAttachedPages``): a pane's page with
    /// the fork's attach call. DevTools and popup windows keep their own window until p03-rendering-056.
    static func attaches(fork: Fork, widget: Widget) -> Bool {
        fork.attachView != nil && widget == .page
    }

    /// Whether a page window hosts, and why not (`debug.cef` `tracker`).
    nonisolated enum Hosting: Equatable, Sendable {
        case hosted
        /// No override and the feature `cefLayerHosting` is off.
        case off
        /// The default keeps a DevTools or popup page window in its own window.
        case widgetFallback
        /// The app makes not every Track A call for this fork (``TrackA/required``).
        case missingTrackA
    }

    /// The kind of page window over the view. By default only a pane's page
    /// hosts: DevTools and popup windows are the per-widget fallback (their own
    /// window) until task p03-rendering-056.
    nonisolated enum Widget: Sendable {
        /// A pane's tabs (`CEFPaneHost`).
        case page
        /// A docked DevTools (`CEFDevToolsController`).
        case devTools
        /// A popup host's window (`CEFPaneHost.isPopupHost`).
        case popup
    }

    /// Whether the page window hosts. `override` (a test's forced hosting) or
    /// the fork's ``Fork/hostsEveryPage`` (the benches' arm): every page window
    /// of a fork from ``forkAPI``. Else the feature `cefLayerHosting`: a pane's
    /// page where the app makes every Track A call for the fork.
    static func hosting(override: Bool, fork: Fork, widget: Widget) -> Hosting {
        if override || fork.hostsEveryPage { return .hosted }
        guard let trackA = fork.trackA else { return .off }
        guard widget == .page else { return .widgetFallback }
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
}
