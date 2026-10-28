#if DEBUG || CMUX_BENCH_HOOKS
import Foundation

/// The `webviews` facet (schemas/oracle/snapshot-v1.schema.json): each loaded cmux page's store
/// summary, as the page itself answers the pane-protocol call `cmux.page.oracle.state`
/// (webviews/src/protocol/oracle-state.ts): its route, selection, open panels and the SHA-256 of its draft. The
/// host adds the page kind and the tab and pane that show it. Chromium reads a page's test state through
/// `window.internals` (third_party/blink/renderer/core/testing/internals.idl), which only a test host installs;
/// here only a DEV or bench app enables the op, and a page answers hashes, never its text.
public struct OracleWebviewsFacet: OracleFacetProvider {
    /// One page's summary.
    public struct Page: Sendable, Hashable {
        /// The page kind (the descriptor id, `cmux.settings`), never an instance.
        public var page: String
        /// The tab that shows the page, nil for a page in no tab (the Settings window, a sidebar).
        public var tab: String?
        public var pane: String?
        public var route: String
        public var selection: String?
        /// Sorted.
        public var panels: [String]
        /// `sha256:<64 hex>`, nil when the page has no draft.
        public var draftSha256: String?

        public init(page: String, tab: String?, pane: String?, route: String, selection: String?, panels: [String],
                    draftSha256: String?) {
            self.page = page
            self.tab = tab
            self.pane = pane
            self.route = route
            self.selection = selection
            self.panels = panels.sorted()
            self.draftSha256 = draftSha256
        }

        /// The page's answer (a Foundation JSON object: `{route, selection, panels, draftSha256}`) with the place
        /// the host knows. An answer of another shape, or a draft that is not a hash, is the page's defect.
        public init(page: String, tab: String?, pane: String?, answer: Any) throws(OracleFacetError) {
            guard let fields = answer as? [String: Any] else { throw OracleFacetError("page \(page): the answer is not an object") }
            guard let route = fields["route"] as? String else { throw OracleFacetError("page \(page): route is not a string") }
            guard let panels = fields["panels"] as? [String] else { throw OracleFacetError("page \(page): panels is not a list of names") }
            let selection = try Self.optionalString(fields["selection"], "selection", page: page)
            let draft = try Self.optionalString(fields["draftSha256"], "draftSha256", page: page)
            if let draft, !Self.isSHA256(draft) { throw OracleFacetError("page \(page): draftSha256 is not sha256:<64 hex>") }
            self.init(page: page, tab: tab, pane: pane, route: route, selection: selection, panels: panels, draftSha256: draft)
        }

        /// The schema's page object.
        public var value: OracleValue {
            [
                "page": .string(page),
                "tab": Self.optional(tab),
                "pane": Self.optional(pane),
                "route": .string(route),
                "selection": Self.optional(selection),
                "panels": .array(panels.map(OracleValue.string)),
                "draftSha256": Self.optional(draftSha256),
            ]
        }

        private static func optional(_ text: String?) -> OracleValue { text.map(OracleValue.string) ?? .null }

        /// A string, or nil for JSON null or a missing field.
        private static func optionalString(_ field: Any?, _ name: String, page: String) throws(OracleFacetError) -> String? {
            guard let field, !(field is NSNull) else { return nil }
            guard let text = field as? String else { throw OracleFacetError("page \(page): \(name) is not a string or null") }
            return text
        }

        static func isSHA256(_ text: String) -> Bool {
            let prefix = "sha256:"
            guard text.hasPrefix(prefix) else { return false }
            let hex = text.utf8.dropFirst(prefix.utf8.count)
            return hex.count == 64 && hex.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }

    /// One reading of every page. A page a person can reach that gave no state (``unserved``, ``loading``,
    /// ``timedOut``) makes the facet not comparable, never a list that silently lacks it: two snapshots of one model
    /// state would otherwise differ by load or answer timing alone.
    public struct Reading: Sendable, Hashable {
        /// The pages that answered, in the host's page order (the schema compares them as a set).
        public var pages: [Page]
        /// Kinds of loaded pages that do not serve the op (a document that does not boot through the shared page
        /// client).
        public var unserved: [String]
        /// Kinds of pages in a tab or a window whose document is still loading (a navigation, a crash reload, a
        /// discarded tab coming back).
        public var loading: [String]
        /// Kinds of pages that did not answer by the host's deadline.
        public var timedOut: [String]

        public init(pages: [Page] = [], unserved: [String] = [], loading: [String] = [], timedOut: [String] = []) {
            self.pages = pages
            self.unserved = unserved
            self.loading = loading
            self.timedOut = timedOut
        }

        /// The facet's value.
        public var value: OracleValue {
            let missing = [("do not serve cmux.page.oracle.state", unserved), ("are loading", loading),
                           ("did not answer in time", timedOut)].filter { !$0.1.isEmpty }
            guard missing.isEmpty else {
                let reason = missing.map { "pages that \($0.0): \(Array(Set($0.1)).sorted().joined(separator: ", "))" }
                return .notComparable(reason: reason.joined(separator: "; "), task: OracleFacet.webviews.task)
            }
            return ["pages": .array(pages.map(\.value))]
        }
    }

    public var facet: OracleFacet { .webviews }
    public let capture: OracleFacetCapture
    public let changes: OracleFacetChanges?

    /// - Parameters:
    ///   - changes: The pages' change signal (a page posted that its reading changed, a page loaded, opened or
    ///     closed), so `debug.oracle.wait_for` can wait on this background facet. Moves between tabs and panes wake
    ///     the wait through the control snapshot's own publishes.
    ///   - read: Asks every page a person can reach, on the main actor (each page's router lives there); the
    ///     snapshot's other background facets run meanwhile. Ends by the host's page deadline. Throws when a page
    ///     answers an error or a bad shape.
    public init(changes: OracleFacetChanges? = nil,
                read: @escaping @MainActor @Sendable () async throws(OracleFacetError) -> Reading) {
        self.changes = changes
        capture = .background { () async throws(OracleFacetError) -> OracleValue in
            try await read().value
        }
    }
}
#endif
