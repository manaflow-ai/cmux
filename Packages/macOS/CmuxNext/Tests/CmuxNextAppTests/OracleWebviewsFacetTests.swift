#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// The oracle's `webviews` facet (p15-oracle-215): a page's `cmux.page.oracle.state` reply becomes one
/// `pages[]` item, only hashes cross, and a page with no answer makes the facet not-comparable.
@MainActor
@Suite struct OracleWebviewsFacetTests {
    private let hash = "sha256:" + String(repeating: "ab", count: 32)
    private let location = OracleWebviewsFacet.Location(tab: "tab_1", pane: "pane_1")

    @Test func aReplyBecomesOneItemWithSortedPanels() throws {
        let reply: JSONValue = ["route": "/settings/general", "selection": "row_7", "panels": ["sidebar", "inspector"],
                                "draftSha256": .string(hash)]
        let entry = try #require(OracleWebviewsFacet.entry(page: "cmux.settings", location: location, reply: reply))
        #expect(entry == JSONValue.object([
            "page": "cmux.settings", "tab": "tab_1", "pane": "pane_1", "route": "/settings/general",
            "selection": "row_7", "panels": ["inspector", "sidebar"], "draftSha256": .string(hash),
        ]))
    }

    @Test func nullsStayNull() throws {
        let reply: JSONValue = ["route": "/", "selection": .null, "panels": [], "draftSha256": .null]
        let entry = try #require(OracleWebviewsFacet.entry(page: "cmux.agent", location: .init(), reply: reply))
        #expect(entry["tab"] == JSONValue.null)
        #expect(entry["pane"] == JSONValue.null)
        #expect(entry["selection"] == JSONValue.null)
        #expect(entry["draftSha256"] == JSONValue.null)
    }

    @Test func aDraftThatIsNotAHashIsRefused() {
        let reply: JSONValue = ["route": "/", "selection": .null, "panels": [], "draftSha256": "my private draft"]
        #expect(OracleWebviewsFacet.entry(page: "cmux.agent", location: location, reply: reply) == nil)
    }

    @Test func anOlderReplyShapeIsRefused() {
        #expect(OracleWebviewsFacet.entry(page: "cmux.agent", location: location, reply: ["claimed": true]) == nil)
        let mixedPanels: JSONValue = ["route": "/", "selection": .null, "panels": ["a", 1], "draftSha256": .null]
        #expect(OracleWebviewsFacet.entry(page: "cmux.agent", location: location, reply: mixedPanels) == nil)
    }

    @Test func hashPattern() {
        #expect(OracleWebviewsFacet.isHash(hash))
        #expect(!OracleWebviewsFacet.isHash("sha256:" + String(repeating: "AB", count: 32)))
        #expect(!OracleWebviewsFacet.isHash("sha256:abc"))
        #expect(!OracleWebviewsFacet.isHash(String(repeating: "ab", count: 32)))
    }

    @Test func noPagesIsAnEmptyList() async {
        let facet = OracleWebviewsFacet(pages: { [] }, locate: { _ in .init() })
        #expect(facet.name == "webviews")
        let value = await facet.snapshot()
        #expect(value == JSONValue.object(["pages": .array([])]))
    }

    @Test func notComparableNamesTheTask() {
        let expected: JSONValue = ["status": "not-comparable", "reason": "why", "task": "p15-oracle-215"]
        #expect(OracleWebviewsFacet.notComparable("why") == expected)
    }
}
#endif
