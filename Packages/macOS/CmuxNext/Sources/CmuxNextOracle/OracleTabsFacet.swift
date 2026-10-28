#if DEBUG || CMUX_BENCH_HOOKS
/// The `tabs` facet (schemas/oracle/snapshot-v1.schema.json): per pane, its shown tab and its
/// browser and page tabs as its strip lists them, with the values a tab strip draws. Chromium's strip reads one
/// engine-neutral value per tab, `TabRendererData` (chrome/browser/ui/tabs/tab_renderer_data.h: url, title,
/// network_state, crashed_status, pinned, alert_state, is_tab_discarded), never the renderer. ``Tab`` is that
/// value; CmuxNextBrowserTabs builds it from the engine-neutral `BrowserTab` protocol only (`engineKind` and
/// `BrowserTabState`), so no field reads an engine type. Whether both engines reach the same state for one
/// navigation is the fleet journey's to show. Titles arrive hashed (`sha256:<hex>`); the find bar is the overlays
/// facet's.
public struct OracleTabsFacet: OracleFacetProvider {
    /// One tab of a pane's strip.
    public struct Tab: Sendable, Hashable {
        public enum Kind: String, Sendable {
            /// A web page (a daemon browser tab or a session-local one).
            case browser
            /// One of cmux's own pages (Settings, the App Store).
            case page
        }

        /// Where the tab's page load is (`BrowserLoadPhase`), or `unloaded` when the tab has no engine page (none
        /// made yet, or a hibernated or not-yet-started stand-in).
        public enum LoadState: String, Sendable {
            case unloaded, idle, provisional, committed, finished, failed
        }

        public var id: String
        public var kind: Kind
        /// The internal page a page tab shows (`InternalPageID`); nil for a browser tab.
        public var page: String?
        public var pinned = false
        /// `BrowserEngineKind` raw value (`webkit`, `cef`); nil for a page tab.
        public var engine: String?
        public var url: String?
        /// `sha256:<hex>` of the title; nil when the tab has none.
        public var titleHash: String?
        public var loadState: LoadState = .unloaded
        public var canGoBack = false
        public var canGoForward = false
        public var zoom: Double = 1
        public var muted = false
        public var audible = false
        /// The page's content process ended (the sad tab).
        public var crashed = false
        /// The page's content process stopped answering input ("Page unresponsive"; Chrome's hung renderer,
        /// `WebContentsDelegate::RendererUnresponsive`).
        public var unresponsive = false
        /// The page was discarded to free memory.
        public var hibernated = false

        public init(id: String, kind: Kind, page: String? = nil) {
            self.id = id
            self.kind = kind
            self.page = page
        }

        /// The schema's object for this tab.
        public var value: OracleValue {
            [
                "tab": .string(id),
                "kind": .string(kind.rawValue),
                "page": Self.optional(page),
                "pinned": .bool(pinned),
                "engine": Self.optional(engine),
                "url": Self.optional(url),
                "title": Self.optional(titleHash),
                "loadState": .string(loadState.rawValue),
                "loading": .bool(loadState == .provisional || loadState == .committed),
                "canGoBack": .bool(canGoBack),
                "canGoForward": .bool(canGoForward),
                "zoom": .number(zoom),
                "muted": .bool(muted),
                "audible": .bool(audible),
                "crashed": .bool(crashed),
                "unresponsive": .bool(unresponsive),
                "hibernated": .bool(hibernated),
            ]
        }

        private static func optional(_ text: String?) -> OracleValue { text.map(OracleValue.string) ?? .null }
    }

    /// One pane: the tab it shows (of any kind, a terminal too) and its browser and page tabs as its strip lists them.
    public struct Pane: Sendable, Hashable {
        public var id: String
        public var selected: String?
        public var tabs: [Tab]

        public init(id: String, selected: String?, tabs: [Tab]) {
            self.id = id
            self.selected = selected
            self.tabs = tabs
        }

        public var value: OracleValue {
            ["pane": .string(id), "selected": selected.map(OracleValue.string) ?? .null, "tabs": .array(tabs.map(\.value))]
        }
    }

    public var facet: OracleFacet { .tabs }
    public let capture: OracleFacetCapture

    /// - Parameter read: The panes now, in the snapshot's main-actor turn; reads model values only.
    public init(read: @escaping @MainActor @Sendable () -> [Pane]) {
        capture = .mainActor { () throws(OracleFacetError) -> OracleValue in
            ["panes": .array(read().map(\.value))]
        }
    }
}
#endif
