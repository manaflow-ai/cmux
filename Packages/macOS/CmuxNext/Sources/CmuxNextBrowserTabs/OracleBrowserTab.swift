#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextBrowser
public import CmuxNextOracle
import Foundation

/// The oracle's `tabs` facet values read through the engine-neutral ``BrowserTab`` protocol:
/// `engineKind` and ``BrowserTabState`` of the live page, else the daemon's tab record when no page exists for
/// the tab. No CEF or WebKit type is read, as Chromium's TabRendererData is built from the WebContents and not
/// the renderer (chrome/browser/ui/tabs/tab_renderer_data.cc, `TabRendererData::FromTabInModel`).
extension OracleTabsFacet.Tab {
    /// What the daemon's record of a browser tab holds, for a tab with no page now.
    public nonisolated struct Record: Sendable, Hashable {
        public var url: String?
        public var title: String?
        public var zoom: Double?
        /// The record's engine tag (`webkit`, `cef`).
        public var engine: String?

        public init(url: String? = nil, title: String? = nil, zoom: Double? = nil, engine: String? = nil) {
            self.url = url
            self.title = title
            self.zoom = zoom
            self.engine = engine
        }
    }

    /// A browser tab: the live `page` when it exists, else its daemon `record`. A stand-in page
    /// (``isStandIn(_:)``) gives its saved address, title, zoom, mute and engine, and nothing live.
    public static func browser(id: String, pinned: Bool, page: (any BrowserTab)?, record: Record,
                               hibernated: Bool) -> OracleTabsFacet.Tab {
        var tab = OracleTabsFacet.Tab(id: id, kind: .browser)
        tab.pinned = pinned
        tab.hibernated = hibernated || page is HibernatedBrowserTab
        guard let page else {
            tab.engine = record.engine
            tab.url = record.url
            tab.titleHash = record.title.map { OracleValue.sha256($0) }
            tab.zoom = record.zoom ?? 1
            return tab
        }
        let state = page.state
        tab.engine = page.engineKind.rawValue
        tab.url = state.url?.absoluteString ?? record.url
        tab.titleHash = (state.title ?? record.title).map { OracleValue.sha256($0) }
        tab.zoom = state.zoom
        tab.muted = state.isAudioMuted
        // No page now: `unloaded`, as Chrome gives a discarded tab TabNetworkState::kNone
        // (chrome/browser/ui/tabs/tab_network_state.cc, TabNetworkStateForWebContents).
        guard !isStandIn(page) else { return tab }
        tab.loadState = OracleTabsFacet.Tab.LoadState(state.phase)
        tab.canGoBack = state.canGoBack
        tab.canGoForward = state.canGoForward
        // The strip's speaker (`BrowserTabAudio.badge`, Chrome's TabAlertState::AUDIO_PLAYING).
        tab.audible = state.media?.isAudible == true
        // Chrome's `crashed_status`: the page's content process ended.
        tab.crashed = state.processExit != nil
        // Chrome's hung renderer: the page shows "Page unresponsive" until it answers or its renderer ends.
        tab.unresponsive = state.isUnresponsive
        return tab
    }

    /// True for the pages TabContentCache keeps in place of an engine page: a hibernated tab's
    /// (``HibernatedBrowserTab``) and a restored tab's not started yet (``DeferredBrowserTab``).
    public static func isStandIn(_ page: any BrowserTab) -> Bool {
        page is HibernatedBrowserTab || page is DeferredBrowserTab
    }

    /// One of cmux's own pages (`page` is its `InternalPageID`), titled as its strip names it.
    public static func page(id: String, page: String, title: String?) -> OracleTabsFacet.Tab {
        var tab = OracleTabsFacet.Tab(id: id, kind: .page, page: page)
        tab.titleHash = title.map { OracleValue.sha256($0) }
        return tab
    }
}

extension OracleTabsFacet.Tab.LoadState {
    public init(_ phase: BrowserLoadPhase) {
        self = switch phase {
        case .idle: .idle
        case .provisional: .provisional
        case .committed: .committed
        case .finished: .finished
        case .failed: .failed
        }
    }
}
#endif
