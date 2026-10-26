#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextOracle
import Testing

/// The oracle's facet list (p15-oracle-030): a facet with no provider answers not-comparable with its
/// task, never absent; only the requested providers run; the main-actor facets are read in one call
/// and the background ones after it; a failing provider fails the whole snapshot, naming its facet in
/// catalog order. Run: `swift test --filter OracleFacetsTests`.
@MainActor
struct OracleFacetsTests {
    /// Counts the reads of the main-actor providers.
    @MainActor final class Reads {
        var facets: [OracleFacet] = []
    }

    /// Counts the reads of the background providers.
    actor BackgroundReads {
        private(set) var facets: [OracleFacet] = []
        func record(_ facet: OracleFacet) { facets.append(facet) }
    }

    private func main(_ facet: OracleFacet, _ value: OracleValue, reads: Reads) -> OracleFacetSource {
        OracleFacetSource(facet, .mainActor { () throws(OracleFacetError) -> OracleValue in
            reads.facets.append(facet)
            return value
        })
    }

    private func background(_ facet: OracleFacet, _ value: OracleValue, reads: BackgroundReads) -> OracleFacetSource {
        OracleFacetSource(facet, .background { () async throws(OracleFacetError) -> OracleValue in
            await reads.record(facet)
            return value
        })
    }

    private func failing(_ facet: OracleFacet, _ message: String) -> OracleFacetSource {
        OracleFacetSource(facet, .background { () async throws(OracleFacetError) -> OracleValue in
            throw OracleFacetError(message)
        })
    }

    @Test func aFacetWithNoProviderIsNotComparableWithItsTask() throws {
        let capture = try OracleFacets([]).beginCapture([.focus, .terminals])
        let snapshot = try #require(capture.completed)
        #expect(snapshot["focus"]?["status"] == "not-comparable")
        #expect(snapshot["focus"]?["task"] == "p15-oracle-034")
        #expect(snapshot["terminals"]?["task"] == "p15-oracle-044")
        #expect(snapshot["layout"] == nil)
    }

    @Test func requestedNamesAreCheckedAndDeduplicated() throws {
        #expect(try OracleFacets.requested(nil) == OracleFacet.allCases)
        #expect(try OracleFacets.requested(["focus", "layout", "focus"]) == [.focus, .layout])
        #expect(throws: OracleRequestError.unknownFacet("fokus")) { try OracleFacets.requested(["focus", "fokus"]) }
        // The daemon facet comes from the daemon, never from the app's list.
        #expect(throws: OracleRequestError.unknownFacet("daemon")) { try OracleFacets.requested(["daemon"]) }
    }

    @Test func onlyRequestedMainActorProvidersRunInTheOneCall() throws {
        let reads = Reads()
        let facets = OracleFacets([main(.focus, ["windows": []], reads: reads), main(.layout, ["screens": []], reads: reads)])
        let capture = try facets.beginCapture([.focus])
        #expect(reads.facets == [.focus])
        #expect(capture.completed == ["focus": ["windows": []]])
    }

    @Test func backgroundFacetsReadAfterTheMainActorCall() async throws {
        let reads = Reads()
        let backgroundReads = BackgroundReads()
        let facets = OracleFacets([
            main(.focus, "focused", reads: reads),
            background(.terminals, ["list": []], reads: backgroundReads),
            background(.crashes, ["exits": []], reads: backgroundReads),
        ])
        let capture = try facets.beginCapture([.focus, .terminals, .crashes, .ax])
        #expect(capture.completed == nil)
        #expect(await backgroundReads.facets.isEmpty)
        let snapshot = try await capture.finish()
        #expect(snapshot["focus"] == "focused")
        #expect(snapshot["terminals"] == ["list": []])
        #expect(snapshot["crashes"] == ["exits": []])
        #expect(snapshot["ax"]?["status"] == "not-comparable")
        let backgroundRead = await backgroundReads.facets
        #expect(Set(backgroundRead) == [.terminals, .crashes])
    }

    @Test func aFailingProviderFailsTheSnapshotInCatalogOrder() async throws {
        let facets = OracleFacets([failing(.liveObjects, "late"), failing(.terminals, "early")])
        let capture = try facets.beginCapture([.liveObjects, .terminals])
        await #expect(throws: OracleSnapshotError(facet: .terminals, error: OracleFacetError("early"))) {
            try await capture.finish()
        }
    }

    @Test func aFailingMainActorProviderFailsBeforeAnyBackgroundRead() async throws {
        let backgroundReads = BackgroundReads()
        let facets = OracleFacets([
            OracleFacetSource(.focus, .mainActor { () throws(OracleFacetError) -> OracleValue in throw OracleFacetError("no window") }),
            background(.terminals, [], reads: backgroundReads),
        ])
        #expect(throws: OracleSnapshotError(facet: .focus, error: OracleFacetError("no window"))) {
            try facets.beginCapture([.terminals, .focus])
        }
        #expect(await backgroundReads.facets.isEmpty)
    }

    @Test func theCatalogListsEveryFacetAndTheFirstProviderAnswers() throws {
        let reads = Reads()
        let facets = OracleFacets([main(.windows, "first", reads: reads), main(.windows, "second", reads: reads)])
        #expect(facets.duplicates == [.windows])
        #expect(facets.provided == [.windows])
        guard case .array(let rows) = facets.catalog else {
            Issue.record("catalog is not a list")
            return
        }
        #expect(rows.count == OracleFacet.allCases.count)
        #expect(rows.contains(["facet": "windows", "provided": true, "task": "p15-oracle-041"]))
        #expect(rows.contains(["facet": "switches", "provided": false, "task": "p15-oracle-027"]))
        #expect(try facets.beginCapture([.windows]).completed == ["windows": "first"])
    }
}
#endif
