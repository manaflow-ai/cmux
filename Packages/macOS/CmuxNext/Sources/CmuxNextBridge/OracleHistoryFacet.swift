#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextDaemon
public import CmuxNextOracle

/// The oracle's `history` facet (schemas/oracle/snapshot-v1.schema.json `history`): the closed items
/// Recently Closed, Search Tabs and Reopen Closed can bring back, newest first. Chromium's TabRestoreService keeps
/// that list in memory, newest first, and reads its file only when it loads
/// (components/sessions/core/tab_restore_service_impl.cc, `TabRestoreServiceImpl::entries()`). Here the daemon owns
/// the closed history (`closed-history-v2`) and the app mirrors its items from `session.events`
/// (`DaemonStore.closedItems`); the facet reads that mirror in the snapshot's main-actor turn and never the disk or
/// a database.
public nonisolated struct OracleHistoryFacet: OracleFacetProvider {
    /// One item a reopen would bring back.
    public nonisolated struct Closed: Sendable, Hashable {
        /// What a reopen recreates: the tab's kind for a close of one tab (`terminal`, `browser`, or `page` for one of
        /// cmux's own pages), `tabs` for one close of several, `group` for a deleted workspace group, else the item's
        /// kind (`screen`, `workspace`, `window`).
        public var kind: String
        /// The text the item is listed by. A shell title holds the cwd and the command, so the facet hashes it.
        public var title: String
        /// The address of a closed browser tab; nil for every other item.
        public var url: String?
        /// The public id (`ws_…`) of the workspace a tab or screen left.
        public var workspace: String?

        public init(kind: String, title: String, url: String? = nil, workspace: String? = nil) {
            self.kind = kind
            self.title = title
            self.url = url
            self.workspace = workspace
        }

        /// The item from the daemon's record only, named as Recently Closed names it (`HistoryService.daemonClosedText`)
        /// with no localized string, so two languages give one facet: the group's name, else the first real name or
        /// address of the item and of its first tab that is not an untouched New Tab page, else that tab's folder.
        public init(_ item: ClosedItem) {
            let tabs = item.tabs, tab = tabs.first { !$0.empty } ?? tabs.first
            kind = if item.group != nil {
                "group"
            } else if item.kind == .tab, tabs.count > 1 {
                "tabs"
            } else if item.kind == .tab, let tab {
                tab.page == nil ? tab.kind : "page"
            } else {
                item.kind.rawValue
            }
            title = item.group?.name ?? Self.shown(item.name) ?? Self.shown(tab?.name) ?? Self.shown(tab?.url)
                ?? tab?.cwd ?? ""
            url = item.kind == .tab && tabs.count == 1 && tab?.page == nil ? Self.shown(tab?.url) : nil
            workspace = item.workspaceID?.rawValue
        }

        /// A name or address worth showing: a chat or New Tab page is kept as a browser tab on `about:blank`.
        private static func shown(_ text: String?) -> String? {
            text.flatMap { $0.isEmpty || $0 == "about:blank" ? nil : $0 }
        }

        /// The schema's object. The title's case root and home become `$ROOT` and `$HOME` before it is hashed (the
        /// schema's `x-oracle-rewrite: path` on a `derive: sha256` field), so one case gives one hash in every run.
        public func value(paths: OraclePaths) -> OracleValue {
            [
                "kind": .string(kind),
                "title": .string(paths.hash(title)),
                "url": url.map(OracleValue.string) ?? .null,
                "workspace": workspace.map(OracleValue.string) ?? .null,
            ]
        }
    }

    public var facet: OracleFacet { .history }
    private let read: @MainActor @Sendable () throws(OracleFacetError) -> [ClosedItem]

    /// - Parameter read: The reopen candidates now, newest first, as Recently Closed lists them; read in the
    ///   snapshot's main-actor turn.
    public init(read: @escaping @MainActor @Sendable () throws(OracleFacetError) -> [ClosedItem]) {
        self.read = read
    }

    public var capture: OracleFacetCapture { capturing(paths: .unchanged) }

    /// Each title hashed after the request's case root and home prefixes are rewritten.
    public func capturing(paths: OraclePaths) -> OracleFacetCapture {
        .mainActor { [read] () throws(OracleFacetError) -> OracleValue in
            ["closed": .array(try read().map { Closed($0).value(paths: paths) })]
        }
    }
}
#endif
