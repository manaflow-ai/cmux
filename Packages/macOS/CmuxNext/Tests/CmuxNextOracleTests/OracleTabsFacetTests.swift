#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextOracle
import Testing

/// The tabs facet's values: each tab is exactly the schema's object
/// (schemas/oracle/snapshot-v1.schema.json `tabs.panes[].tabs[]`, additionalProperties false), `loading` follows
/// the load state, and the facet answers `{panes: [...]}` in the snapshot's main-actor turn.
/// Run: `swift test --filter OracleTabsFacetTests`.
@MainActor
struct OracleTabsFacetTests {
    static let schemaKeys: Set<String> = [
        "tab", "kind", "page", "pinned", "engine", "url", "title", "loadState", "loading", "canGoBack", "canGoForward",
        "zoom", "muted", "audible", "crashed", "unresponsive", "hibernated",
    ]

    private func keys(_ value: OracleValue) -> Set<String> {
        if case .object(let members) = value { return Set(members.keys) }
        return []
    }

    @Test func aTabIsTheSchemasObject() {
        var tab = OracleTabsFacet.Tab(id: "tab_1", kind: .browser)
        tab.engine = "cef"
        tab.url = "https://example.com/"
        tab.titleHash = "sha256:" + String(repeating: "0", count: 64)
        tab.loadState = .committed
        tab.zoom = 1.25
        tab.pinned = true
        #expect(keys(tab.value) == Self.schemaKeys)
        #expect(tab.value["loading"] == true)
        #expect(tab.value["loadState"] == "committed")
        #expect(tab.value["engine"] == "cef")
        #expect(tab.value["page"] == .null)
        #expect(tab.value["zoom"] == 1.25)
        #expect(tab.value["pinned"] == true)
    }

    @Test func loadingIsOnlyAnOpenNavigation() {
        for state in [OracleTabsFacet.Tab.LoadState.unloaded, .idle, .provisional, .committed, .finished, .failed] {
            var tab = OracleTabsFacet.Tab(id: "tab_1", kind: .browser)
            tab.loadState = state
            #expect(tab.value["loading"] == .bool(state == .provisional || state == .committed), "\(state)")
        }
    }

    @Test func aPageTabHasNoEngineOrURL() {
        let value = OracleTabsFacet.Tab(id: "local-page:settings:1", kind: .page, page: "settings").value
        #expect(keys(value) == Self.schemaKeys)
        #expect(value["kind"] == "page")
        #expect(value["page"] == "settings")
        #expect(value["engine"] == .null)
        #expect(value["url"] == .null)
        #expect(value["title"] == .null)
        #expect(value["loadState"] == "unloaded")
    }

    @Test func theFacetListsItsPanes() throws {
        let tab = OracleTabsFacet.Tab(id: "local-page:settings:1", kind: .page, page: "settings")
        let facet = OracleTabsFacet { [OracleTabsFacet.Pane(id: "pane_1", selected: "tab_9", tabs: [tab])] }
        #expect(facet.facet == .tabs)
        let snapshot = try #require(try OracleFacets([facet]).beginCapture([.tabs]).completed)
        #expect(snapshot["tabs"] == ["panes": [["pane": "pane_1", "selected": "tab_9", "tabs": [tab.value]]]])
        let empty = try #require(try OracleFacets([OracleTabsFacet { [] }]).beginCapture([.tabs]).completed)
        #expect(empty["tabs"] == ["panes": []])
    }
}
#endif
