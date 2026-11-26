import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Leo, 2026-11-23 (paraphrased): the iPhone chat keeps saying the Mac "was unreachable for more
/// than 10 seconds" when it was not; maybe the attachments just can't get through in time. Fix it
/// at the root, and stop showing long, unactionable connection messages.
///
/// A held prompt's window counts only time without a usable link: an upload or a slow write on a
/// ready link is not "unreachable". A large write still going out holds its channel, so a read
/// queued behind it does not rebind the channel and lose the prompt. A link that is really down
/// past the window still returns the draft, with a short line.
@MainActor
@Suite struct HeldPromptSlowWriteTests {
    /// The prompts' clock (`AcpmuxSessionSource.now`): moved by hand, so a write "takes" 25 s at once.
    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        var now: ContinuousClock.Instant { lock.withLock { instant } }
        func advance(by duration: Duration) { lock.withLock { instant += duration } }
    }

    /// A Mac's `acpmux` channel whose prompt writes are slow. Each `session/prompt` write takes the
    /// next of `writes` (past the end: answered at once) and moves the clock by `writeTakes`:
    /// `hang` never finishes (its bound cuts it off); `fail` throws at once; `gate` goes out once the test opens the gate,
    /// and every read written meanwhile is answered only after it (it queues behind the bytes).
    final class SlowMac: LinkChannel, @unchecked Sendable {
        enum Write { case answer, hang, gate, fail }
        let id: UInt32 = 1
        private let mac: ChatPromptBlipTests.Mac
        private let clock: FakeClock
        private let writeTakes: Duration
        private let lock = NSLock()
        private var writes: [Write]
        private var sendingPrompt = false
        private var queued: [Data] = []
        private var gate: CheckedContinuation<Void, Never>?
        private var gateOpen = false
        private var _promptWrites = 0
        private var closeInfo: LinkError?
        var closedBy: LinkError? { lock.withLock { closeInfo } }
        private let inbox: AsyncStream<Data>
        private let continuation: AsyncStream<Data>.Continuation
        private var iterator: AsyncStream<Data>.AsyncIterator

        init(_ mac: ChatPromptBlipTests.Mac, clock: FakeClock, writes: [Write] = [], writeTakes: Duration = .zero) {
            self.mac = mac
            self.clock = clock
            self.writes = writes
            self.writeTakes = writeTakes
            (inbox, continuation) = AsyncStream.makeStream()
            iterator = inbox.makeAsyncIterator()
        }

        var isSendingPrompt: Bool { lock.withLock { sendingPrompt } }
        var promptWrites: Int { lock.withLock { _promptWrites } }

        func openGate() {
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                gateOpen = true
                defer { gate = nil }
                return gate
            }
            waiting?.resume()
        }

        private func waitForGate() async {
            await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
                let open = lock.withLock { () -> Bool in
                    if gateOpen { return true }
                    gate = waiting
                    return false
                }
                if open { waiting.resume() }
            }
        }

        func send(_ data: Data) async throws {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize":
                continuation.yield(reply(#"{"protocolVersion":1,"_meta":{"acpmux":{"fullAccess":true}}}"#))
            case "_acpmux/watch":
                continuation.yield(reply(#"{"sessions":[{"sessionId":"s1","name":"lane","harness":"claude","cwd":"/tmp/w","status":"running"}]}"#))
            case "_acpmux/attach":
                continuation.yield(reply(#"{"session":{"sessionId":"s1","status":"running","pending":[]},"hasMore":false,"lastSeq":0,"events":[]}"#))
            case "session/prompt":
                let mode = lock.withLock { () -> Write in
                    _promptWrites += 1
                    return writes.isEmpty ? .answer : writes.removeFirst()
                }
                clock.advance(by: writeTakes)
                switch mode {
                case .hang:
                    // Cancelled by the write's bound (LinkDeadline), which throws here.
                    try await Task.sleep(for: .seconds(3600))
                    return
                case .fail:
                    throw LinkError(code: "write_failed", message: "write failed")
                case .gate:
                    lock.withLock { sendingPrompt = true }
                    await waitForGate()
                case .answer:
                    break
                }
                let params = object["params"] as? [String: Any]
                let text = ((params?["prompt"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                let meta = (params?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
                mac.prompted(text, meta?["promptId"] as? String ?? "", meta?["resend"] as? Bool ?? false)
                continuation.yield(reply(#"{"stopReason":"end_turn"}"#))
                let behind = lock.withLock { () -> [Data] in
                    sendingPrompt = false
                    defer { queued = [] }
                    return queued
                }
                for data in behind { continuation.yield(data) }
            default:
                let answer: Data
                switch method {
                case "_acpmux/sessions": answer = reply(#"{"sessions":[{"sessionId":"s1","harness":"claude"}],"nextCursor":null}"#)
                case "_acpmux/harnesses": answer = reply(#"{"harnesses":[]}"#)
                default: answer = reply("{}")
                }
                let later = lock.withLock { () -> Bool in
                    if sendingPrompt { queued.append(answer) }
                    return sendingPrompt
                }
                if !later { continuation.yield(answer) }
            }
        }

        func receive() async throws -> Data? { await iterator.next() }
        func close(code: String, reason: String) async {
            lock.withLock { closeInfo = LinkError(code: code, message: reason) }
            continuation.finish()
        }
    }

    func openChat(_ channel: SlowMac, clock: FakeClock) async -> (AcpmuxHub, AcpmuxSessionSource, AgentChatStore) {
        let hub = AcpmuxHub()
        // A prompt write's fixed bound, a tenth of a second instead of 30 s (the file's tests are quick).
        hub.writeBase = .milliseconds(100)
        await hub.bind(channel)
        #expect(hub.isReady)
        let source = hub.source(sessionID: "s1", summary: ChatPromptBlipTests.summary)
        source.now = { clock.now }
        let store = AgentChatStore(source: source)
        for _ in 0..<200 { await Task.yield() }
        return (hub, source, store)
    }

    /// Waits, bounded, for real-time work (a write's 100 ms bound, the held prompts' 500 ms flush).
    func eventually(_ condition: () -> Bool) async {
        // By deadline, not by count: on a loaded runner a 10 ms sleep takes far longer.
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    #if canImport(CmuxMobileLinkFFI)
    /// (a) A prompt whose write took longer than the window (a large attachment on a slow link)
    /// and then failed is held, not bounced as "unreachable": it is delivered once the link is
    /// back, with no notice and no draft returned.
    @Test func aWriteLongerThanTheWindowThatFailsIsHeldAndDeliveredOnce() async throws {
        let mac = ChatPromptBlipTests.Mac()
        let clock = FakeClock()
        let first = SlowMac(mac, clock: clock, writes: [.hang, .hang, .hang], writeTakes: .seconds(25))
        let (hub, source, store) = await openChat(first, clock: clock)
        defer { withExtendedLifetime(hub) {} }

        store.send(prompt: "look at this screenshot")
        await eventually { source.heldPrompts.count == 1 }
        #expect(source.heldPrompts.map(\.text) == ["look at this screenshot"])
        #expect(store.clientError == nil, "a slow write on a ready link is not an outage")
        #expect(store.returnedDraft == nil)

        // The link drops and comes back within the window (counted from the failure).
        await hub.bind(nil)
        await hub.bind(SlowMac(mac, clock: clock))
        await eventually { mac.prompts.count == 1 }
        for _ in 0..<200 { await Task.yield() }
        #expect(mac.prompts.map(\.text) == ["look at this screenshot"], "delivered exactly once")
        #expect(source.heldPrompts.isEmpty)
        #expect(store.clientError == nil)
        #expect(store.returnedDraft == nil)
    }
    #endif

    #if canImport(CmuxMobileLinkFFI)
    /// (b) A prompt write that times out on a ready link says nothing within the window, though
    /// each write took longer than the window; past a window with no write getting through, the
    /// draft comes back with the short line.
    @Test func aWriteTimeoutOnAReadyLinkSaysNothingWithinTheWindow() async throws {
        let mac = ChatPromptBlipTests.Mac()
        let clock = FakeClock()
        let channel = SlowMac(mac, clock: clock, writes: Array(repeating: .hang, count: 100), writeTakes: .seconds(25))
        let (hub, source, store) = await openChat(channel, clock: clock)
        defer { withExtendedLifetime(hub) {} }

        store.send(prompt: "run the tests")
        // The first write times out; the outbox retries after its backoff (on the prompts' clock,
        // so the test moves it) and the second times out again.
        await eventually { source.heldPrompts.count == 1 }
        clock.advance(by: .seconds(2))
        await eventually { channel.promptWrites >= 2 && source.heldPrompts.count == 1 }
        #expect(channel.promptWrites >= 2)
        #expect(store.clientError == nil)
        #expect(store.returnedDraft == nil)
        #expect(mac.prompts.isEmpty)

        // A whole window passes between two attempts (the prompt is held, not being written;
        // the outbox gives back only what is queued, never one mid-write): the draft comes back.
        await eventually { source.heldPrompts.count == 1 }
        // Past the window the outbox holds (``AgentChatStore/sendDeadline``), not a number of its own.
        clock.advance(by: source.heldPromptWindow + .seconds(1))
        await eventually { store.turns.last?.localSend == .notSent }
        #expect(store.turns.last?.prompt == "run the tests")
        #expect(store.returnedDraft == nil)
        #expect(store.clientError == nil)
    }
    #endif

    #if canImport(CmuxMobileLinkFFI)
    /// (b2) A write that fails at once, again and again, on a channel that still says ready is
    /// not held for good: each failure moves the wait on only by what the write took (nothing),
    /// so the window still runs out and the draft comes back.
    @Test func aWriteThatFailsAtOnceOnAReadyLinkStillComesBackAfterTheWindow() async throws {
        let mac = ChatPromptBlipTests.Mac()
        let clock = FakeClock()
        let channel = SlowMac(mac, clock: clock, writes: Array(repeating: .fail, count: 1000))
        let (hub, source, store) = await openChat(channel, clock: clock)
        defer { withExtendedLifetime(hub) {} }

        store.send(prompt: "run the tests")
        await eventually { channel.promptWrites >= 1 && source.heldPrompts.count == 1 }
        #expect(store.returnedDraft == nil)
        // A few seconds at a time (past each retry's backoff, which is on the prompts' clock),
        // with a failed attempt in each: never a whole window between two attempts, so only a
        // wait that is not restarted by each failure can run out (the Rust outbox ages it from
        // the first failure and moves it on by what each write took: nothing here).
        // Enough 4 s steps to pass the window the outbox holds (``AgentChatStore/sendDeadline``), and two more.
        let steps = Int(source.heldPromptWindow / .seconds(4)) + 2
        for _ in 0..<steps where store.turns.last?.localSend != .notSent {
            let before = channel.promptWrites
            clock.advance(by: .seconds(4))
            // The prompt is queued (not mid-write) whenever the test moves the clock, so the
            // advance is never counted as time a write took.
            await eventually {
                (channel.promptWrites > before && source.heldPrompts.count == 1) || store.turns.last?.localSend == .notSent
            }
        }
        await eventually { store.turns.last?.localSend == .notSent }
        #expect(store.turns.last?.prompt == "run the tests")
        #expect(store.clientError == nil)
        #expect(mac.prompts.isEmpty)
    }
    #endif

    /// (c) A read stalled behind a large prompt write still going out on the same channel is slow,
    /// not stalled: the channel is not rebound (which cut the write off and sent the prompt twice
    /// or bounced it), the read answers once the write is through, and the prompt arrives once.
    @Test func aReadBehindALargeWriteStillBeingSentDoesNotRebindTheChannel() async throws {
        let mac = ChatPromptBlipTests.Mac()
        let clock = FakeClock()
        let channel = SlowMac(mac, clock: clock, writes: [.gate])
        let (hub, _, store) = await openChat(channel, clock: clock)
        defer { withExtendedLifetime(hub) {} }
        hub.writeBase = .seconds(30)
        hub.stallAfter = .milliseconds(50)
        var stalls = 0
        hub.onStall = { stalls += 1; await hub.bind(SlowMac(mac, clock: clock)) }

        store.send(prompt: "here is the 8 MB PDF")
        await eventually { channel.isSendingPrompt }
        #expect(channel.isSendingPrompt)
        let read = Task { @MainActor in
            try await hub.request("_acpmux/sessions", .object(["limit": .number(100)]), timeout: .seconds(5))
        }
        // test: past the stall bound and its probe's (50 ms each) while the write is still going out
        try await Task.sleep(for: .milliseconds(300))
        #expect(stalls == 0, "no rebind while a write is still being sent")
        channel.openGate()
        _ = try await read.value
        await eventually { mac.prompts.count >= 1 }
        for _ in 0..<300 { await Task.yield() }
        #expect(stalls == 0)
        #expect(mac.prompts.map(\.text) == ["here is the 8 MB PDF"], "the prompt arrives exactly once")
        #expect(store.clientError == nil)
        #expect(store.returnedDraft == nil)
    }

    @Test func aRetiredPartialMessageChannelIsReopenedBeforeTheNextPrompt() async throws {
        let mac = ChatPromptBlipTests.Mac()
        let clock = FakeClock()
        let first = SlowMac(mac, clock: clock)
        let (hub, _, store) = await openChat(first, clock: clock)
        var rebinds = 0
        hub.onStall = {
            rebinds += 1
            await hub.bind(SlowMac(mac, clock: clock))
        }
        await first.close(code: "partial_message", reason: "write was cancelled")
        await eventually { rebinds == 1 && hub.isReady }
        #expect(rebinds == 1)
        store.send(prompt: "next")
        await eventually { !mac.prompts.isEmpty }
        #expect(mac.prompts.map(\.text) == ["next"])
        #expect(store.returnedDraft == nil)
    }

    #if canImport(CmuxMobileLinkFFI)
    @Test func preparationCompletingNinetySecondsAfterTapStillDeliversInOrder() async throws {
        let mac = ChatPromptBlipTests.Mac()
        let clock = FakeClock()
        let (hub, _, store) = await openChat(SlowMac(mac, clock: clock), clock: clock)
        defer { withExtendedLifetime(hub) {} }
        // The attachment's completed upload is on the Mac. Both taps are recorded synchronously,
        // and neither queued MainActor preparation task hands off its payload until we yield.
        let file = AgentAttachment(kind: .file, name: "clip.mov", macPath: "/w/clip.mov")
        store.send(prompt: "see clip", attachments: [file])
        store.send(prompt: "then reply")
        clock.advance(by: .seconds(90))
        await eventually { mac.prompts.count == 2 }
        #expect(mac.prompts.map(\.text) == ["see clip", "then reply"])
        #expect(store.returnedDraft == nil)
    }
    #endif

    /// The write bound grows with the payload: 30 s, plus its bytes at 16 KiB/s.
    @Test func theWriteBoundScalesWithThePayload() {
        #expect(AcpmuxConnection.writeBound(bytes: 0) == .seconds(30))
        #expect(AcpmuxConnection.writeBound(bytes: 16 * 1024) == .seconds(31))
        // An 8 MiB inline attachment: 30 s + 512 s.
        #expect(AcpmuxConnection.writeBound(bytes: 8 << 20) == .seconds(542))
    }
}
