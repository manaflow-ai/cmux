@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextSignposts
@testable import CmuxNextTrace
import Foundation
import Testing

/// The omnibar's side of `key.omnibar_suggest` (perf-hot `omnibar-key`): each typed key's
/// reducer pass is one slice whose end holds the popup's rows, and the pass that takes the query's rows when they land
/// is one slice of its own.
@Suite struct OmnibarSuggestSignpostTests {
    private nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        /// The `key.omnibar_suggest` records as (phase, arg0).
        var slices: [(TraceRuntime.Phase, UInt64)] {
            state.withLock { $0 }.filter { $0.name == SignpostName.keyOmnibarSuggest.rawValue }.map { ($0.phase, $0.arg0) }
        }

        func signposter() -> Signposter {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategories([.key])
            return Signposter(category: .key, trace: runtime)
        }
    }

    private static func field(_ text: String) -> OmnibarInput {
        .fieldChanged(.init(text: text, selection: NSRange(location: text.utf16.count, length: 0)), .insert)
    }

    private static func rows(_ count: Int) -> [BrowserSuggestion] {
        (0..<count).map {
            BrowserSuggestion(kind: .history, title: "example \($0)", detail: "", url: URL(string: "https://example.com/\($0)")!,
                              score: 1)
        }
    }

    @Test func aTypedKeyAndItsRowsAreOneSliceEachWithThePopupRows() throws {
        let log = RecordLog()
        let signposter = log.signposter()
        var state = OmnibarReducer.reduce(OmnibarState(), .focusGained(.keyboard), resolver: OmniboxResolver(),
                                          signposter: signposter).state
        #expect(log.slices.isEmpty, "focus alone runs no suggestion pass")

        state = OmnibarReducer.reduce(state, Self.field("e"), resolver: OmniboxResolver(), signposter: signposter).state
        let generation = state.generation
        state = OmnibarReducer.reduce(state, .suggestions(generation: generation, rows: Self.rows(3)),
                                      resolver: OmniboxResolver(), signposter: signposter).state
        #expect(state.popup.rows.count == 3)

        let query = Signposter.KeySearchPass.query.rawValue
        let results = Signposter.KeySearchPass.results.rawValue
        try #require(log.slices.count == 4)
        #expect(log.slices.map { $0.0 } == [.begin, .end, .begin, .end])
        #expect(log.slices.map { $0.1 } == [query, 0, results, 3])

        // The next key keeps the stale rows on screen until fresh ones land: its end counts them.
        _ = OmnibarReducer.reduce(state, Self.field("ex"), resolver: OmniboxResolver(), signposter: signposter)
        #expect(log.slices.suffix(2).map { $0.1 } == [query, 3])
    }

    /// A keyword session's start (Opt-Cmd-F, Tab to search) and its end (Backspace at the start) each start a query
    /// without a typed key's edit: each is one query slice too, as Chrome traces every AutocompleteController::Start.
    @Test func aKeywordSessionsStartAndEndAreOneQuerySliceEach() {
        let log = RecordLog()
        let signposter = log.signposter()
        var resolver = OmniboxResolver()
        resolver.keywords = OmnibarKeyword.searchEngines(default: resolver.searchEngine)
        var state = OmnibarReducer.reduce(OmnibarState(), .focusGained(.keyboard), resolver: resolver,
                                          signposter: signposter).state
        let query = Signposter.KeySearchPass.query.rawValue

        state = OmnibarReducer.reduce(state, .key(.searchWithDefaultEngine), resolver: resolver, signposter: signposter).state
        #expect(state.keyword != nil)
        #expect(log.slices.map { $0.0 } == [.begin, .end])
        #expect(log.slices.map { $0.1 } == [query, 0])

        state = OmnibarReducer.reduce(state, .key(.backspaceAtStart), resolver: resolver, signposter: signposter).state
        #expect(state.keyword == nil)
        #expect(log.slices.map { $0.0 } == [.begin, .end, .begin, .end])
        #expect(log.slices.suffix(2).map { $0.1 } == [query, 0])
    }
}
