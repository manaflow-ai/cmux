#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextOracle
import Foundation
import Testing

/// The webviews facet: each page's answer to `cmux.page.oracle.state` with the host's place for
/// it, in the schema's shape; an answer of another shape or an unhashed draft fails the snapshot; a loaded page
/// that does not serve the op makes the facet not-comparable, never a list that lacks it.
/// Run: `swift test --filter OracleWebviewsFacetTests`.
@MainActor
struct OracleWebviewsFacetTests {
    private static let hash = "sha256:" + String(repeating: "ab", count: 32)

    @Test func aPagesAnswerIsTheSchemasObject() async throws {
        let answer: [String: Any] = ["route": "/settings/theme", "selection": NSNull(), "panels": ["picker", "dialog"],
                                     "draftSha256": Self.hash]
        let page = try OracleWebviewsFacet.Page(page: "cmux.agent", tab: "tab_1", pane: "pane_1", answer: answer)
        let facet = OracleWebviewsFacet { OracleWebviewsFacet.Reading(pages: [page]) }
        #expect(facet.facet == .webviews)
        let capture = try OracleFacets([facet]).beginCapture([.webviews])
        #expect(capture.completed == nil, "pages answer off the snapshot's main-actor turn")
        let snapshot = try await capture.finish()
        #expect(snapshot["webviews"] == ["pages": [[
            "page": "cmux.agent", "tab": "tab_1", "pane": "pane_1", "route": "/settings/theme", "selection": nil,
            "panels": ["dialog", "picker"], "draftSha256": .string(Self.hash),
        ]]])
    }

    @Test func aPageInNoTabHasNullPlaceAndAMissingSelectionIsNull() throws {
        let page = try OracleWebviewsFacet.Page(page: "cmux.settings", tab: nil, pane: nil,
                                                answer: ["route": "/", "panels": [String](), "draftSha256": NSNull()] as [String: Any])
        #expect(page.value == [
            "page": "cmux.settings", "tab": nil, "pane": nil, "route": "/", "selection": nil, "panels": [], "draftSha256": nil,
        ])
    }

    @Test func aBadAnswerIsThePagesDefect() {
        let bad: [[String: Any]] = [
            ["panels": [String]()],
            ["route": "/", "panels": "picker"],
            ["route": "/", "panels": [String](), "selection": 3],
            ["route": "/", "panels": [String](), "draftSha256": "the draft text itself"],
            ["route": "/", "panels": [String](), "draftSha256": "sha256:" + String(repeating: "AB", count: 32)],
        ]
        for answer in bad {
            #expect(throws: OracleFacetError.self) {
                try OracleWebviewsFacet.Page(page: "cmux.agent", tab: nil, pane: nil, answer: answer)
            }
        }
        #expect(throws: OracleFacetError.self) {
            try OracleWebviewsFacet.Page(page: "cmux.agent", tab: nil, pane: nil, answer: ["/"])
        }
    }

    @Test func anUnservedPageMakesTheFacetNotComparable() async throws {
        let facet = OracleWebviewsFacet { OracleWebviewsFacet.Reading(pages: [], unserved: ["cmux.diff", "cmux.diff"]) }
        let snapshot = try await OracleFacets([facet]).beginCapture([.webviews]).finish()
        #expect(snapshot["webviews"]?["status"] == "not-comparable")
        #expect(snapshot["webviews"]?["task"] == "p15-oracle-215")
        #expect(snapshot["webviews"]?["reason"] == "pages that do not serve cmux.page.oracle.state: cmux.diff")
    }

    @Test func aLoadingOrSilentPageMakesTheFacetNotComparable() async throws {
        let page = try OracleWebviewsFacet.Page(page: "cmux.agent", tab: "tab_1", pane: "pane_1",
                                                answer: ["route": "/", "panels": [String]()] as [String: Any])
        let facet = OracleWebviewsFacet {
            OracleWebviewsFacet.Reading(pages: [page], loading: ["cmux.settings"], timedOut: ["cmux.diff", "cmux.agent"])
        }
        let snapshot = try await OracleFacets([facet]).beginCapture([.webviews]).finish()
        #expect(snapshot["webviews"]?["status"] == "not-comparable")
        #expect(snapshot["webviews"]?["reason"]
            == "pages that are loading: cmux.settings; pages that did not answer in time: cmux.agent, cmux.diff")
    }

    @Test func thePagesChangeSignalWakesAWait() async {
        let (signals, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let facets = OracleFacets([OracleWebviewsFacet(changes: { signals }) { OracleWebviewsFacet.Reading() }])
        #expect(facets.signalsChanges(.webviews))
        var changes = facets.changes(.webviews)?().makeAsyncIterator()
        signal.yield()
        #expect(await changes?.next() != nil)
    }

    @Test func aPageErrorFailsTheSnapshot() async throws {
        let facet = OracleWebviewsFacet { () async throws(OracleFacetError) -> OracleWebviewsFacet.Reading in
            throw OracleFacetError("page cmux.agent: cmux.oracle.no_digest")
        }
        await #expect(throws: OracleSnapshotError(facet: .webviews, error: OracleFacetError("page cmux.agent: cmux.oracle.no_digest"))) {
            try await OracleFacets([facet]).beginCapture([.webviews]).finish()
        }
    }
}
#endif
