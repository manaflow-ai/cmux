#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextAgentPane
import CmuxNextHomeEngine
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The oracle's `webviews` facet (plans/cmux-next/chrome-parity/p15-oracle.md 3A, task p15-oracle-215;
/// schema `/facets/webviews` of schemas/oracle/snapshot-v1.schema.json): each live app page's store
/// summary `{page, tab, pane, route, selection, panels, draftSha256}`.
///
/// The host asks every page at once with the host-to-page call `cmux.page.oracle.state`
/// (webviews/src/protocol/oracle-state.ts) and waits one deadline for all of them. The page hashes
/// its drafts itself, so no private text reaches the host. Pages serve the op only in the builds
/// that compile this file (PageWebView+Pooled.swift sets `data-oracle="on"`). A page that does not
/// answer makes the facet not-comparable, never a partial list.
@MainActor
struct OracleWebviewsFacet {
    /// Where a page shows, by the ids the topology facet uses; nil when it shows in no tab.
    struct Location: Equatable, Sendable {
        var tab: String?
        var pane: String?
    }

    /// The facet's key under `facets` and the task that owns it.
    static let facetName = "webviews"
    static let task = "p15-oracle-215"
    /// The page op (`ORACLE_STATE_OP` in oracle-state.ts).
    static let op = "cmux.page.oracle.state"

    private let pages: @MainActor () -> [PageWebView]
    private let locate: @MainActor (PageWebView) -> Location
    private let deadline: Duration
    private let clock: any Clock<Duration>

    /// - Parameters:
    ///   - pages: The live page views, oldest first (the composition root passes `PageRegistry.pages()`).
    ///   - locate: The tab and pane that show a page.
    ///   - deadline: How long the pages together have to answer.
    ///   - clock: The deadline's clock.
    init(pages: @escaping @MainActor () -> [PageWebView], locate: @escaping @MainActor (PageWebView) -> Location,
         deadline: Duration = .seconds(1), clock: any Clock<Duration> = ContinuousClock()) {
        self.pages = pages
        self.locate = locate
        self.deadline = deadline
        self.clock = clock
    }

    var name: String { Self.facetName }

    /// The facet value. Reading it changes no state: the page op only reads its stores.
    func snapshot() async -> JSONValue {
        // The parked spare has no routes and no store: it is no page a person sees.
        let live = pages().filter { !$0.isParkedSpare }
        let routers = live.map(\.router)
        let deadline = self.deadline, clock = self.clock
        let answers = await withTaskGroup(of: (Int, JSONValue?).self) { group in
            for (index, router) in routers.enumerated() {
                group.addTask { @MainActor in
                    let answer = await PageAnswerDeadline(deadline, clock: clock).answer {
                        try await router.callPage(Self.op, params: .object([:]))
                    }
                    return (index, answer)
                }
            }
            var answers = [JSONValue?](repeating: nil, count: routers.count)
            for await (index, answer) in group { answers[index] = answer }
            return answers
        }
        var entries: [JSONValue] = []
        var silent: [String] = []
        for (page, answer) in zip(live, answers) {
            if let answer, let entry = Self.entry(page: page.pageID, location: locate(page), reply: answer) {
                entries.append(entry)
            } else {
                silent.append(page.pageID)
            }
        }
        guard silent.isEmpty else {
            return Self.notComparable("no oracle state from page \(silent.sorted().joined(separator: ", "))")
        }
        return ["pages": .array(entries)]
    }

    /// One `pages[]` item from a page's reply; nil when the reply is not the op's shape (an older page,
    /// or a draft that is not a hash).
    static func entry(page: String, location: Location, reply: JSONValue) -> JSONValue? {
        guard let fields = reply.objectValue, let route = fields["route"]?.stringValue,
              let selection = fields["selection"], isStringOrNull(selection),
              let draft = fields["draftSha256"], draft == .null || draft.stringValue.map(isHash) == true,
              let items = fields["panels"]?.arrayValue else { return nil }
        let panels = items.compactMap(\.stringValue)
        guard panels.count == items.count else { return nil }
        return .object([
            "page": .string(page),
            "tab": location.tab.map(JSONValue.string) ?? .null,
            "pane": location.pane.map(JSONValue.string) ?? .null,
            "route": .string(route),
            "selection": selection,
            "panels": .array(panels.sorted().map(JSONValue.string)),
            "draftSha256": draft,
        ])
    }

    static func notComparable(_ reason: String) -> JSONValue {
        ["status": "not-comparable", "reason": .string(reason), "task": .string(task)]
    }

    private static func isStringOrNull(_ value: JSONValue) -> Bool {
        value == .null || value.stringValue != nil
    }

    /// `sha256:` and 64 lowercase hex digits (the schema's hash pattern).
    static func isHash(_ text: String) -> Bool {
        let prefix = "sha256:"
        guard text.hasPrefix(prefix) else { return false }
        let hex = text.dropFirst(prefix.count)
        return hex.count == 64 && hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

extension AppServices {
    /// The `webviews` facet over this process's live pages, for the facet list the composition root
    /// builds (AppServices+Oracle.swift, task p15-oracle-030).
    func oracleWebviewsFacet() -> OracleWebviewsFacet {
        OracleWebviewsFacet(pages: { PageRegistry.pages() }, locate: { [weak self] page in
            self?.oracleLocation(of: page) ?? .init()
        })
    }

    /// The tab that shows `page` in a shown pane, with the pane's key: an app-only page tab's key, a
    /// store page tab's id, or an agent tab's id. Read from the tab stores' existing views (never
    /// made here: `madeAgentTabs`, not `agentTabs`); a page of a hidden workspace has none.
    private func oracleLocation(of page: PageWebView) -> OracleWebviewsFacet.Location {
        for controller in windows.controllers {
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
                for key in pages.tabIDs(in: pane.paneKey) where pages.existingView(key)?.content === page {
                    return .init(tab: key, pane: pane.paneKey)
                }
                for tab in pane.pane.tabs {
                    let pageTab = pages.storeKey(of: tab.id).flatMap { pages.existingView($0)?.content }
                    guard pageTab === page || madeAgentTabs?.existingView(tab.id)?.debugPage === page else { continue }
                    return .init(tab: tab.id, pane: pane.paneKey)
                }
            }
        }
        return .init()
    }
}
#endif
