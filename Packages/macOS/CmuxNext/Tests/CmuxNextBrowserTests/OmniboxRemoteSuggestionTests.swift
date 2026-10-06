@testable import CmuxNextBrowser
import Foundation
import Testing

/// Phase B (plans/cmux-next/omnibar-suggestions.md): remote search
/// suggestions start 40 ms after the last keystroke, stop at 800 ms, end
/// with the query that asked, never leave for private-looking input, and
/// join the card without moving what is on screen. Fake fetcher, manual clock.
@MainActor
@Suite struct OmniboxRemoteSuggestionTests {
    private struct Rig {
        let engine = OmniboxSuggestionEngine()
        let clock = ManualClock()
        let fetcher = FakeSuggestFetcher()
        let gate = OmniboxGenerationGate()

        init(configure: (inout OmniboxRemoteConfiguration) -> Void = { _ in }) {
            var remote = OmniboxRemoteConfiguration(fetcher: fetcher)
            remote.clock = clock
            configure(&remote)
            engine.remote = remote
        }

        func stream(_ text: String, generation: UInt64 = 1) -> AsyncStream<OmniboxDelivery> {
            gate.begin(generation)
            return engine.deliveries(for: OmniboxRequest(text: text, generation: generation, gate: gate))
        }
    }

    @Test func remoteRowsArriveAfterTheDebounceFromTheEnginesSuggestEndpoint() async throws {
        let rig = Rig()
        var deliveries = rig.stream("swift").makeAsyncIterator()
        guard case .local(let local)? = await deliveries.next() else {
            Issue.record("no local rows")
            return
        }
        #expect(local.first?.title == "swift")
        await rig.clock.sleepers(atLeast: 1)
        rig.clock.advance(by: .milliseconds(39))
        #expect(rig.fetcher.requests.isEmpty, "nothing before 40 ms")
        rig.clock.advance(by: .milliseconds(1))
        await rig.fetcher.requests(atLeast: 1)
        #expect(rig.fetcher.requests == [.init(url: try #require(BrowserSearchEngine.google.suggestURL(for: "swift")), ephemeral: false)])
        rig.fetcher.respond(FakeSuggestFetcher.openSearch("swift", ["swift", "swift ui", "Swift UI", "swiftlang"]))
        guard case .more(let rows, let capacity)? = await deliveries.next() else {
            Issue.record("no remote rows")
            return
        }
        #expect(rows.map(\.title) == ["swift ui", "swiftlang"])
        #expect(rows.allSatisfy { $0.kind == .search && !$0.inlineCompletable })
        #expect(capacity == 8)
        #expect(await deliveries.next() == nil)
    }

    @Test func aNewKeystrokeCancelsTheDebounceAndAnOldAnswerNeverDelivers() async {
        let rig = Rig()
        let first = Task { () -> Int in
            var count = 0
            for await _ in rig.stream("swi") { count += 1 }
            return count
        }
        await rig.clock.sleepers(atLeast: 1)
        first.cancel()
        _ = await first.value
        rig.clock.advance(by: .milliseconds(100))
        #expect(rig.fetcher.requests.isEmpty, "the cancelled query never fetched")

        // A request in flight when the generation moves on: its answer is dropped.
        var second = rig.stream("swif", generation: 2).makeAsyncIterator()
        _ = await second.next()
        await rig.clock.sleepers(atLeast: 1)
        rig.clock.advance(by: .milliseconds(40))
        await rig.fetcher.requests(atLeast: 1)
        rig.gate.begin(3)
        rig.fetcher.respond(FakeSuggestFetcher.openSearch("swif", ["swift"]))
        #expect(await second.next() == nil)
    }

    @Test func aSlowRequestIsCancelledAtTheTimeout() async {
        let rig = Rig()
        var deliveries = rig.stream("weather").makeAsyncIterator()
        _ = await deliveries.next()
        await rig.clock.sleepers(atLeast: 1)
        rig.clock.advance(by: .milliseconds(40))
        await rig.fetcher.requests(atLeast: 1)
        await rig.clock.sleepers(atLeast: 1)
        rig.clock.advance(by: .milliseconds(799))
        #expect(rig.fetcher.cancellations == 0)
        rig.clock.advance(by: .milliseconds(1))
        #expect(await deliveries.next() == nil)
        #expect(rig.fetcher.cancellations == 1)
    }

    @Test func privateLookingInputNeverLeavesAndTheSettingTurnsItOff() async {
        let resolver = OmniboxResolver()
        for text in ["localhost:3000", "127.0.0.1:8080", "192.168.1.20", "/Users/ada/notes.md", "~/src", "file:///etc/hosts",
                     "github.com", "https://example.com/a b", "nas:5000", "[::1]", String(repeating: "a", count: 2_100)] {
            #expect(!OmniboxRemoteSuggestions.allows(text, resolver: resolver), "\(text)")
        }
        for text in ["swift concurrency", "weather"] {
            #expect(OmniboxRemoteSuggestions.allows(text, resolver: resolver), "\(text)")
        }
        let off = Rig { $0.enabled = false }
        var none = off.stream("weather").makeAsyncIterator()
        _ = await none.next()
        #expect(await none.next() == nil)
        #expect(off.fetcher.requests.isEmpty)
        let local = Rig()
        var address = local.stream("localhost:3000").makeAsyncIterator()
        _ = await address.next()
        #expect(await address.next() == nil)
        #expect(local.fetcher.requests.isEmpty)
    }

    @Test func aPrivateProfileFetchesEphemerally() async {
        let rig = Rig { $0.isPrivate = true }
        var deliveries = rig.stream("weather").makeAsyncIterator()
        _ = await deliveries.next()
        await rig.clock.sleepers(atLeast: 1)
        rig.clock.advance(by: .milliseconds(40))
        await rig.fetcher.requests(atLeast: 1)
        #expect(rig.fetcher.requests.first?.ephemeral == true)
        rig.fetcher.respond(FakeSuggestFetcher.openSearch("weather", ["weather today"]))
        #expect(await deliveries.next() != nil)
    }

    @Test func suggestResponsesAndEngines() throws {
        #expect(OmniboxRemoteSuggestions.parse(FakeSuggestFetcher.openSearch("q", ["a", "b"])) == ["a", "b"])
        #expect(OmniboxRemoteSuggestions.parse(Data("[\"caf\",[\"caf\u{E9}\"]]".utf8)) == ["café"])
        let latin1 = try #require("[\"caf\",[\"caf\u{E9}\"]]".data(using: .isoLatin1))
        #expect(OmniboxRemoteSuggestions.parse(latin1) == ["café"])
        #expect(OmniboxRemoteSuggestions.parse(Data("<html>".utf8)).isEmpty)
        #expect(Set(BrowserSearchEngine.builtIn.map(\.id)) == ["google", "duckduckgo", "bing", "brave", "kagi"])
        #expect(BrowserSearchEngine.builtIn.allSatisfy { $0.suggestURL(for: "a b&c")?.absoluteString.contains("a%20b%26c") == true })
        let custom = BrowserSearchEngine.custom(search: "https://www.search.example/find?q=%s", suggest: "https://search.example/ac?q=%s")
        #expect(custom.name == "search.example")
        #expect(custom.searchURL(for: "x y")?.absoluteString == "https://www.search.example/find?q=x%20y")
        #expect(custom.suggestURL(for: "x")?.absoluteString == "https://search.example/ac?q=x")
        #expect(BrowserSearchEngine.custom(search: "https://s.example/", suggest: "").searchURL(for: "x") == nil)
    }

    @Test func lateRowsJoinWithoutMovingTheSelection() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("swi", settle: false)
        let generation = sim.queries.last?.generation ?? 0
        let primary = OmniboxPhaseA.primary(for: "swi", resolver: sim.resolver)
        let local = [primary].compactMap { $0 } + ["https://swift.org/", "https://swiftpackageindex.com/"].enumerated().map { index, url in
            var row = BrowserSuggestion(kind: .history, title: url, detail: url, url: URL(string: url)!, score: 700 - Double(index))
            row.inlineCompletable = false
            return row
        }
        sim.send(.suggestions(generation: generation, rows: local))
        sim.key(.down)
        let remote = ["swift ui", "swiftly"].enumerated().map { index, title in
            BrowserSuggestion(kind: .search, title: title, detail: "", url: URL(string: "https://www.google.com/search?q=\(index)")!, score: 200 - Double(index))
        }
        sim.send(.moreSuggestions(generation: generation, rows: remote, capacity: 4))
        #expect(sim.state.popup.rows.map(\.title) == local.map(\.title) + ["swift ui"])
        #expect(sim.state.popup.selected == 1)
        #expect(sim.field.text == "https://swift.org/")
        // An older generation's late rows are dropped.
        sim.send(.moreSuggestions(generation: generation - 1, rows: [remote[1]], capacity: 8))
        #expect(sim.state.popup.rows.count == 4)
    }
}
