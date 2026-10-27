import CmuxFuzzSupport
import CmuxNextSettings
import Foundation
import Testing
import WebKit
@testable import CmuxNextPages

/// Seeded fuzz of the page bridge (plans/cmux-next/chrome-parity/p10-stability.md, task 179): what a page posts
/// through `window.webkit.messageHandlers` (WebKit's `WKScriptMessage.body`) or a Chromium page's binding (the
/// DevTools text ``ChromiumPageHostWire`` reads), and the envelopes ``PageRouter`` handles. Bodies no JSON holds
/// (a `Date`, `Data`, NaN, a number key), dictionaries with two keys that are equal Swift strings, wrong types,
/// huge strings, ids no counter reaches, and replies to host calls in any order. Chrome fuzzes its WebUI and
/// Mojo boundary the same way (mojo/public/tools/fuzzers/mojolpm, content/test/fuzzer).
///
/// The properties: no message traps; a malformed one is dropped or refused and counted once
/// (``PageRouter/badMessages``, ``PageInputReadiness/badMessages``); every other envelope gets the reply the
/// router's contract names (``PageBridgeModel``); and the page still answers a good call afterwards.
///
/// It runs only with `CMUX_PAGE_BRIDGE_FUZZ=1`; agents run it on the fleet, CI does not (Lawrence 2026-10-23):
///
/// ```
/// CMUX_PAGE_BRIDGE_FUZZ=1 swift test --filter PageBridgeFuzzTests
/// CMUX_PAGE_BRIDGE_FUZZ=1 CMUX_FUZZ_DEADLINE=$(( $(date +%s) + 300 )) swift test --filter PageBridgeFuzzTests
/// ```
///
/// `CMUX_FUZZ_SEED` and `CMUX_FUZZ_ITERATIONS` replay a failure; with `CMUX_FUZZ_ARTIFACTS` set a trap leaves
/// its case behind (`PageBridge.<run>.inflight`). The suite is serialized, so `CMUX_FUZZ_DEADLINE` is split
/// equally between its ``runCount`` runs.
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_PAGE_BRIDGE_FUZZ"] == "1",
        "set CMUX_PAGE_BRIDGE_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    )
)
struct PageBridgeFuzzTests {
    /// Two minutes past a long run's budget, so the limit stops a hang and never a long run.
    nonisolated static let timeLimitMinutes: Int = {
        let budget = (try? FuzzEnvironment.current())?.longModeBudget(from: Date()) ?? 0
        return 2 + Int((budget / 60).rounded(.up))
    }()

    /// The suite's runs (its `@Test`s), which share a `CMUX_FUZZ_DEADLINE`.
    nonisolated static let runCount = 6

    /// Each run's share of `CMUX_FUZZ_DEADLINE`, fixed when the first run asks; nil without a deadline or in a replay.
    nonisolated static let deadlineShare: TimeInterval? = {
        guard let environment = try? FuzzEnvironment.current(), environment.iterations == nil,
              let deadline = environment.deadline else { return nil }
        return max(deadline.timeIntervalSinceNow, 0) / Double(runCount)
    }()

    /// A run of this suite: the process's `CMUX_FUZZ_*` variables, its long mode capped at ``deadlineShare``.
    nonisolated static func run(_ name: String, seed: UInt64, iterations: Int) throws(FuzzError) -> FuzzRun {
        var environment = try FuzzEnvironment.current()
        if let share = deadlineShare { environment.seconds = min(environment.seconds ?? share, share) }
        return FuzzRun(name, seed: seed, iterations: iterations, environment: environment)
    }

    /// One input of the checks that need no main actor, its choices read from `data` (the libFuzzer entry,
    /// p10-stability-182; CmuxNextPages imports WebKit, so the Linux wrappers skip it).
    nonisolated static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        switch rng.below(3) {
        case 0: try PageBridgeWire.generated(&rng)
        case 1: try PageBridgeCase.bridge(PageFuzzBody.random(&rng))
        default: try PageBridgeWire.anyText(rng.bytes(4096))
        }
    }

    @Test(.timeLimit(.minutes(PageBridgeFuzzTests.timeLimitMinutes)))
    func oneInputTakesAnyBytes() throws {
        let run = try Self.run("PageBridge.oneInput", seed: 0xB41D_0179_0001, iterations: 3_000)
        let seeds = [Data(), Data([0]), Data([1, 11, 3, 0]), Data([2, 0x7B, 0x22]), Data(repeating: 0x5A, count: 64)]
        try run.forEachInput(try run.corpus(seeds: seeds)) { try Self.oneInput($0) }
    }

    /// Envelopes in any order through a real router get the contract's replies, count each malformed one,
    /// reach the provider only when admitted, end host calls with the page's own replies, and leave the page live.
    @Test(.timeLimit(.minutes(PageBridgeFuzzTests.timeLimitMinutes)))
    func routerKeepsItsContract() async throws {
        try await Self.run("PageBridge.router", seed: 0xB41D_0179_0002, iterations: 2_000).forEachAwaiting { rng in
            try await PageBridgeCase.router(&rng)
        }
    }

    /// Any body an engine hands over reads as JSON or is refused and counted, through the router, the
    /// readiness handler and the Chromium reply, never a trap.
    @Test(.timeLimit(.minutes(PageBridgeFuzzTests.timeLimitMinutes)))
    func bodiesNeverTrap() async throws {
        let page = PageBridgeCase.Page()
        let readiness = PageInputReadiness(configuration: WKWebViewConfiguration())
        try await Self.run("PageBridge.bodies", seed: 0xB41D_0179_0003, iterations: 4_000).forEachAwaiting { rng in
            try await PageBridgeCase.bodies(&rng, page: page, readiness: readiness)
        }
        let live = await page.router.handle(["t": "call", "id": 1, "op": "cmux.fuzz.echo"])
        #expect(PageBridgeModel.matches(live, .ok(1, ["op": "cmux.fuzz.echo"])), "the page is not live: \(live.compactText)")
    }

    /// Generated DevTools events, payloads and evaluations read as their parts say.
    @Test(.timeLimit(.minutes(PageBridgeFuzzTests.timeLimitMinutes)))
    func wireReadsItsParts() throws {
        try Self.run("PageBridge.wire", seed: 0xB41D_0179_0004, iterations: 8_000).forEach { rng in
            try PageBridgeWire.generated(&rng)
        }
    }

    /// Byte and token mutations of real wire text through every reader.
    @Test(.timeLimit(.minutes(PageBridgeFuzzTests.timeLimitMinutes)))
    func mutatedWireNeverTraps() throws {
        let run = try Self.run("PageBridge.mutatedWire", seed: 0xB41D_0179_0005, iterations: 8_000)
        let mutator = FuzzMutator(dictionary: PageBridgeWire.tokens, maximumCount: 16_384)
        try run.forEachInput(try run.corpus(seeds: PageBridgeWire.seeds()), mutator: mutator) { try PageBridgeWire.anyText($0) }
    }
}

/// The bad messages the page bridge fuzz found (p10-stability-179), fixed cases that run without
/// `CMUX_PAGE_BRIDGE_FUZZ`: each trapped before the fix.
struct PageBridgeBadMessageTests {
    /// Two keys that are equal Swift strings (U+00E9 and U+0065 U+0301), from either engine: one member, no trap.
    @Test func equalKeysReadAsOneMember() async throws {
        for text in PageBridgeWire.equalKeys {
            let object = ChromiumPageHostWire.object(text)
            #expect(object != nil, "\(text) read as nothing")
        }
        let message = ChromiumPageHostWire.Message(payload: PageBridgeWire.equalKeys[0])
        #expect((message?.body as? [String: Any])?.count == 1)
        let body = NSMutableDictionary()
        body.setObject(NSNumber(value: true), forKey: NSString(string: "\u{E9}"))
        body.setObject(NSNumber(value: false), forKey: NSString(string: "e\u{301}"))
        body.setObject(NSNumber(value: true), forKey: NSString(string: "ready"))
        let readiness = PageInputReadiness(configuration: WKWebViewConfiguration())
        readiness.receive(body)
        #expect(readiness.isReady && readiness.badMessages == 0)
        let page = PageBridgeCase.Page()
        #expect(page.router.envelope(body)?.objectValue?.count == 2)
        #expect(page.router.envelope([Date()] as NSArray) == nil && page.router.badMessages == 1)
        let reply = await page.router.handle(["t": "unsub", "sub": .number(1e300)])
        #expect(reply == .null && page.router.badMessages == 2, "a sub past every counter is refused and counted, not a trap")
    }
}
