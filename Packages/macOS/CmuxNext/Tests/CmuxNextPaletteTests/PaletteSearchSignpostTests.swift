import AppKit
import CmuxNextActions
import CmuxNextCompat
@testable import CmuxNextPalette
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// The palette's side of `key.palette_search` (perf-hot `palette-key`): a typed query is one
/// slice in `search` and one when its rows land, whose end holds the rows shown; nothing is written while the key
/// category is off.
@MainActor @Suite(.paletteRanker, .serialized)
struct PaletteSearchSignpostTests {
    private final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        /// The `key.palette_search` records as (phase, arg0) pairs.
        var slices: [(TraceRuntime.Phase, UInt64)] {
            state.withLock { $0 }.filter { $0.name == SignpostName.keyPaletteSearch.rawValue }.map { ($0.phase, $0.arg0) }
        }

        func signposter(recording: Bool) -> Signposter {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(recording ? 1 << UInt64(SignpostCategory.key.traceBit) : 0)
            return Signposter(category: .key, trace: runtime)
        }
    }

    private static func row(_ id: String, _ title: String) -> PaletteItem {
        PaletteItem(id: id, title: title, primary: PaletteCommand(id: "show", title: "Show", symbol: "return", effect: .perform {}))
    }

    private static func palette(_ signposter: Signposter) async -> PaletteController {
        _ = NSApplication.shared
        let palette = PaletteController(registry: ActionRegistry.standard(), sources: PaletteSources(), frecencyPersistence: nil)
        palette.model.keySignposter = signposter
        palette.model.reset(to: PalettePageSpec(id: "live", title: "Live", placeholder: "", providers: [], queryResults: { query in
            query.isEmpty ? [] : [Self.row("b", "zeta build failed"), Self.row("a", "Build ok")]
        }, filtersByQuery: false))
        await palette.model.settle()
        return palette
    }

    @Test func aTypedQueryIsOneSliceAndItsRowsAnother() async throws {
        let log = RecordLog()
        let palette = await Self.palette(log.signposter(recording: true))
        defer { palette.hide() }
        let before = log.slices.count
        palette.model.send(.setQuery("build"))
        await palette.model.settle()

        let slices = Array(log.slices.dropFirst(before))
        try #require(slices.count >= 4)
        #expect(slices.map { $0.0 } == Array(repeating: [TraceRuntime.Phase.begin, .end], count: slices.count / 2).flatMap { $0 })
        #expect(slices.first?.1 == Signposter.KeySearchPass.query.rawValue)
        // The pass that showed the page's answer ends with its two rows.
        #expect(slices.suffix(2).map { $0.1 } == [Signposter.KeySearchPass.results.rawValue, 2])
        #expect(palette.model.rows.count == 2)
    }

    @Test func nothingIsRecordedWithTheKeyCategoryOff() async {
        let log = RecordLog()
        let palette = await Self.palette(log.signposter(recording: false))
        defer { palette.hide() }
        palette.model.send(.setQuery("build"))
        await palette.model.settle()

        #expect(log.slices.isEmpty)
        #expect(palette.model.rows.count == 2)
    }
}
