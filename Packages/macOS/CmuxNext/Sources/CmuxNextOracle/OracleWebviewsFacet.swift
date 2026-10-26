#if DEBUG || CMUX_BENCH_HOOKS
import Foundation

/// The `webviews` facet (schemas/oracle/snapshot-v1.schema.json, p15-oracle-215): each loaded cmux page's store
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

    /// One reading of every page.
    public struct Reading: Sendable, Hashable {
        /// The pages that answered, in the host's page order (the schema compares them as a set).
        public var pages: [Page]
        /// Kinds of loaded pages that do not serve the op (a document that does not boot through the shared page
        /// client): the facet is then not comparable, never a list that silently lacks them.
        public var unserved: [String]

        public init(pages: [Page] = [], unserved: [String] = []) {
            self.pages = pages
            self.unserved = unserved
        }

        /// The facet's value.
        public var value: OracleValue {
            guard unserved.isEmpty else {
                let names = Array(Set(unserved)).sorted().joined(separator: ", ")
                return .notComparable(reason: "pages that do not serve cmux.page.oracle.state: \(names)", task: OracleFacet.webviews.task)
            }
            return ["pages": .array(pages.map(\.value))]
        }
    }

    public var facet: OracleFacet { .webviews }
    public let capture: OracleFacetCapture

    /// - Parameter read: Asks every loaded page, on the main actor (each page's router lives there); the
    ///   snapshot's other background facets run meanwhile. Throws when a page answers an error or a bad shape.
    public init(read: @escaping @MainActor @Sendable () async throws(OracleFacetError) -> Reading) {
        capture = .background { () async throws(OracleFacetError) -> OracleValue in
            try await read().value
        }
    }
}
#endif
