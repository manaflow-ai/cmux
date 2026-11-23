import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Leo 2026-11-21: "i keep seeing "the mac didnt answer in time" i dont want to see that + just
/// fix the connection to be smoother better faster". A replayed link: the three ways a chat-list
/// read reached the person as an error, each run against the hub as it was (`steadyReads` off:
/// the request goes to the channel as it is, and fails when it fails) and as it is now (waits
/// for a channel coming back; a stalled or closed read recovers the channel once and is asked
/// again). Each prints one `LINKBENCH {json}` line: answered, errors the person would see, and
/// the median time to the answer (or to the error).
///
/// Deadlines are a tenth of the app's (a 2 s read instead of 20 s, a 0.6 s stall instead of 6 s,
/// a 1 s grace instead of 10 s), so the suite stays quick; the shape is the same.
@MainActor
@Suite(.serialized) struct LinkSmoothnessBenchTests {
    static let trials = 5
    static let readTimeout: Duration = .seconds(2)

    /// A Mac's acpmux channel. `healthy` answers everything; `quiet` answers the bind
    /// (`initialize`, the watch) and then nothing; `busy` is alive but slow (it answers the bind
    /// and the harness list, nothing else); `closing` closes when asked for the list.
    final class BenchMac: LinkChannel, @unchecked Sendable {
        enum Mode { case healthy, quiet, busy, closing }
        let id: UInt32 = 1
        let mode: Mode
        private let inbox: AsyncStream<Data>
        private let continuation: AsyncStream<Data>.Continuation
        private var iterator: AsyncStream<Data>.AsyncIterator

        init(_ mode: Mode) {
            self.mode = mode
            (inbox, continuation) = AsyncStream.makeStream()
            iterator = inbox.makeAsyncIterator()
        }

        func send(_ data: Data) async throws {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) { continuation.yield(Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8)) }
            switch method {
            case "initialize": reply(#"{"protocolVersion":1}"#)
            case "_acpmux/watch": reply(#"{"sessions":[{"sessionId":"s1","name":"s1","harness":"fake","cwd":"/tmp","status":"idle"}]}"#)
            default:
                switch mode {
                case .healthy where method == "_acpmux/sessions":
                    reply(#"{"sessions":[{"sessionId":"s1","harness":"fake"}],"nextCursor":null}"#)
                case .healthy: reply("{}")
                case .busy where method == "_acpmux/harnesses": reply(#"{"harnesses":[]}"#)
                case .quiet, .busy: break
                case .closing: continuation.finish()
                }
            }
        }

        func receive() async throws -> Data? { await iterator.next() }
        func close(code: String, reason: String) async { continuation.finish() }
    }

    struct Outcome {
        var answered = 0
        var errors: [String] = []
        var millis: [Double] = []
        var median: Double { millis.sorted()[millis.count / 2] }
    }

    func hub(steady: Bool) -> AcpmuxHub {
        let hub = AcpmuxHub()
        hub.steadyReads = steady
        hub.readyGrace = .seconds(1)
        hub.stallAfter = .milliseconds(600)
        return hub
    }

    /// One chat-list read as the Chats list asks for it, timed.
    func read(_ hub: AcpmuxHub, into outcome: inout Outcome) async {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await hub.request("_acpmux/sessions", .object(["limit": .number(100)]), timeout: Self.readTimeout)
            outcome.answered += 1
        } catch {
            outcome.errors.append((error as? LinkError)?.code ?? "other")
        }
        let elapsed = start.duration(to: clock.now)
        outcome.millis.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
    }

    func report(_ scenario: String, _ steady: Bool, _ outcome: Outcome) {
        let line: [String: Any] = [
            "scenario": scenario, "build": steady ? "after" : "before", "trials": Self.trials,
            "answered": outcome.answered, "visible_errors": outcome.errors.count,
            "error_codes": Array(Set(outcome.errors)).sorted(), "median_ms": Int(outcome.median.rounded()),
        ]
        let json = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        print("LINKBENCH \(json)")
        // The simulator step keeps attachments in its evidence (kit-attachments/), not stdout.
        Attachment.record("LINKBENCH \(json)\n", named: "linkbench-\(scenario)-\(steady ? "after" : "before").txt")
    }

    /// The `acpmux` channel goes quiet while the Mac's link stays up (its heartbeat probes the
    /// link, not the channel). Recovery here is what the coordinator does: a fresh channel.
    func quietChannel(steady: Bool) async -> Outcome {
        var outcome = Outcome()
        for _ in 0..<Self.trials {
            let hub = hub(steady: steady)
            await hub.bind(BenchMac(.quiet))
            hub.onStall = { await hub.bind(BenchMac(.healthy)) }
            await read(hub, into: &outcome)
            await hub.bind(nil)
        }
        return outcome
    }

    /// The channel closes under the read (the Mac's acpmux restarted, the stream reset).
    func closedChannel(steady: Bool) async -> Outcome {
        var outcome = Outcome()
        for _ in 0..<Self.trials {
            let hub = hub(steady: steady)
            await hub.bind(BenchMac(.closing))
            hub.onStall = { await hub.bind(BenchMac(.healthy)) }
            await read(hub, into: &outcome)
            await hub.bind(nil)
        }
        return outcome
    }

    /// The read is asked while the link comes back (every foreground after the app was in the
    /// background redials): the channel is bound 300 ms later.
    func duringReconnect(steady: Bool) async -> Outcome {
        var outcome = Outcome()
        for _ in 0..<Self.trials {
            let hub = hub(steady: steady)
            let comesBack = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                await hub.bind(BenchMac(.healthy))
            }
            await read(hub, into: &outcome)
            await comesBack.value
            await hub.bind(nil)
        }
        return outcome
    }

    /// The Mac is really gone: the read still fails, after the grace, never forever.
    func macGone(steady: Bool) async -> Outcome {
        var outcome = Outcome()
        for _ in 0..<Self.trials {
            await read(hub(steady: steady), into: &outcome)
        }
        return outcome
    }

    @Test func aQuietChannelIsReplacedAndTheReadAnswers() async {
        let before = await quietChannel(steady: false)
        let after = await quietChannel(steady: true)
        report("quiet_channel", false, before)
        report("quiet_channel", true, after)
        #expect(before.errors.count == Self.trials)
        #expect(after.answered == Self.trials)
        // Answered well before the read's own deadline (the stall bound plus a rebind).
        #expect(after.median < 1500)
    }

    @Test func aClosedChannelIsReplacedAndTheReadAnswers() async {
        let before = await closedChannel(steady: false)
        let after = await closedChannel(steady: true)
        report("closed_channel", false, before)
        report("closed_channel", true, after)
        #expect(before.errors.count == Self.trials)
        #expect(after.answered == Self.trials)
    }

    @Test func aReadDuringAReconnectWaitsForTheChannel() async {
        let before = await duringReconnect(steady: false)
        let after = await duringReconnect(steady: true)
        report("during_reconnect", false, before)
        report("during_reconnect", true, after)
        #expect(before.errors.count == Self.trials)
        #expect(after.answered == Self.trials)
    }

    @Test func aMacThatIsGoneStillSaysSoWithinTheGrace() async {
        let before = await macGone(steady: false)
        let after = await macGone(steady: true)
        report("mac_gone", false, before)
        report("mac_gone", true, after)
        #expect(before.answered == 0 && after.answered == 0)
        #expect(after.errors == Array(repeating: "offline", count: Self.trials))
        #expect(after.median < 2000)
    }

    /// A mutation is never sent twice: a quiet channel's `session/new` fails at its deadline,
    /// recovers nothing and is not asked again.
    @Test func aMutationIsNeverRetried() async {
        let hub = hub(steady: true)
        await hub.bind(BenchMac(.quiet))
        var stalls = 0
        hub.onStall = { stalls += 1 }
        await #expect(throws: LinkError.self) {
            _ = try await hub.request("session/new", .object([:]), timeout: .milliseconds(300))
        }
        #expect(stalls == 0)
    }

    /// A read slow behind a prompt or mutation still in flight never replaces the channel: that
    /// would cut the write off on a channel that is only slow. The read keeps its own deadline,
    /// and the write keeps its channel to the end.
    @Test func aReadSlowBehindAWriteLeavesTheChannelAlone() async {
        let hub = hub(steady: true)
        let mac = BenchMac(.busy)
        await hub.bind(mac)
        var stalls = 0
        hub.onStall = { stalls += 1; await hub.bind(BenchMac(.healthy)) }
        let write = Task { @MainActor in
            try await hub.request("session/new", .object([:]), timeout: .seconds(3))
        }
        await Task.yield()
        var outcome = Outcome()
        await read(hub, into: &outcome)
        #expect(stalls == 0, "no rebind while a write is in flight")
        #expect(outcome.answered == 0)
        #expect(outcome.errors.count == 1)
        // The write ran to its own deadline on the channel it was sent on.
        await #expect(throws: LinkError.self) { _ = try await write.value }
        #expect(stalls == 0)
    }

    /// A channel that is dead under a write (it answers nothing, not even the cheap probe) is
    /// still recovered: the write is lost with it either way, and the read answers on the new one.
    @Test func aDeadChannelUnderAWriteIsStillRecovered() async {
        let hub = hub(steady: true)
        await hub.bind(BenchMac(.quiet))
        var stalls = 0
        hub.onStall = { stalls += 1; await hub.bind(BenchMac(.healthy)) }
        let write = Task { @MainActor in
            try await hub.request("session/new", .object([:]), timeout: .seconds(3))
        }
        await Task.yield()
        var outcome = Outcome()
        await read(hub, into: &outcome)
        #expect(stalls == 1)
        #expect(outcome.answered == 1)
        await #expect(throws: (any Error).self) { _ = try await write.value }
    }

    /// A channel replaced while the stalled read's probe waits (another recovery, or the link's own
    /// reconnect, bound a fresh one) is not recovered a second time: the read is asked again on
    /// the new channel, and `onStall` never runs (#49130 F1).
    @Test func aRebindDuringTheProbeIsNotFollowedByASecondRecovery() async throws {
        let hub = hub(steady: true)
        await hub.bind(BenchMac(.quiet))
        var stalls = 0
        hub.onStall = { stalls += 1; await hub.bind(BenchMac(.healthy)) }
        let write = Task { @MainActor in
            try await hub.request("session/new", .object([:]), timeout: .seconds(3))
        }
        // The stall watch fires at 600 ms and probes for up to 600 ms more; the rebind lands inside it.
        let rebind = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(900))
            await hub.bind(BenchMac(.healthy))
        }
        await Task.yield()
        var outcome = Outcome()
        await read(hub, into: &outcome)
        try await rebind.value
        // Past the probe's bound: a second recovery, if any, has run by now.
        try await Task.sleep(for: .milliseconds(800))
        #expect(stalls == 0, "the channel was already replaced: no second recovery")
        #expect(outcome.answered == 1)
        _ = try? await write.value
    }

    /// A prompt answered before its `reply(to:)` is asked for is no longer in flight: it never
    /// keeps a later stalled read from recovering the channel.
    @Test func anAnsweredSubmitIsNoLongerAWriteInFlight() async throws {
        let hub = hub(steady: true)
        await hub.bind(BenchMac(.healthy))
        let (connection, id) = try await hub.submit("session/prompt", .object([:]))
        for _ in 0..<200 where await connection.hasWritesInFlight {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await connection.hasWritesInFlight == false)
        _ = try await connection.reply(to: id)
        #expect(await connection.hasWritesInFlight == false)
    }
}
