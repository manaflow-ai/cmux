import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// The `key.omnibar_suggest` and `key.palette_search` slices (perf-hot `omnibar-key` and
/// `palette-key`): each pass is one B/E pair with its pass code in the B and the list's row count in the E, nothing is
/// written while the key category is off, and nothing at all, not even the begin, while the keystroke-timing gate is
/// closed. Each test records into its own runtime.
@Suite struct KeySearchSignpostTests {
    private nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        func runtime() -> TraceRuntime {
            TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
        }
    }

    private struct Rig {
        let log = RecordLog()
        let runtime: TraceRuntime
        let key: Signposter

        init(categories: TraceCategories = [.key]) {
            runtime = log.runtime()
            runtime.setCategories(categories)
            key = Signposter(category: .key, mirror: SignpostMetricKitMirror(), trace: runtime)
        }

        func records(_ name: SignpostName) -> [TraceRuntime.StubRecord] {
            log.records.filter { $0.name == name.rawValue }
        }
    }

    @Test(arguments: [SignpostName.keyOmnibarSuggest, .keyPaletteSearch])
    func eachPassIsOneThreadSliceWithItsCodeAndItsRowCount(_ name: SignpostName) {
        let rig = Rig()
        let query = rig.key.begin(name, searchPass: .query)
        rig.key.end(name, query, results: 4)
        let rows = rig.key.begin(name, searchPass: .results)
        rig.key.end(name, rows, results: 7)

        let records = rig.records(name)
        #expect(records.map(\.phase) == [.begin, .end, .begin, .end])
        #expect(records.map(\.arg0) == [Signposter.KeySearchPass.query.rawValue, 4,
                                         Signposter.KeySearchPass.results.rawValue, 7])
        #expect(query?.isTraced == true)
    }

    @Test func aMoreRowsPassCarriesItsOwnCode() {
        let rig = Rig()
        rig.key.end(.keyOmnibarSuggest, rig.key.begin(.keyOmnibarSuggest, searchPass: .moreResults), results: 0)

        #expect(rig.records(.keyOmnibarSuggest).map(\.arg0) == [Signposter.KeySearchPass.moreResults.rawValue, 0])
    }

    @Test func theRingTakesNothingWithTheKeyCategoryOff() {
        let rig = Rig(categories: [])
        let slice = rig.key.begin(.keyPaletteSearch, searchPass: .query)
        rig.key.end(.keyPaletteSearch, slice, results: 3)

        #expect(slice?.isTraced != true)
        #expect(rig.log.records.isEmpty)
    }

    @Test func theKeystrokeTimingGateOpensNoSliceAndReadsNoCount() {
        let rig = Rig()
        rig.runtime.setKeyTimingSuppressed(true, by: .terminalSecureInput)
        var countsRead = 0
        let slice = rig.key.begin(.keyOmnibarSuggest, searchPass: .query)
        rig.key.end(.keyOmnibarSuggest, slice, results: { countsRead += 1; return 2 }())

        #expect(slice == nil)
        #expect(countsRead == 0)
        #expect(rig.log.records.isEmpty)
    }
}
