#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import Dispatch
import Darwin
import Foundation
import Testing
@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport

/// The input-turn hop recorder (plans/cmux-next/chrome-parity/p04-input.md, task 022): hops from one
/// call site fold into one row with their count, kinds and origins, hops from two call sites into
/// two rows; the site is the first frame past the runtime frames after the entry image; the ring
/// holds 64 records and the tables 128 sites; non-Swift callouts are timed when input was pending at
/// their start or end and at their own run-loop depth, and a sampled one counts under its site;
/// reset starts the since-reset window over; the rows encode as `debug.input hops` returns them.
@MainActor @Suite(.timeLimit(.minutes(1))) struct InputTurnHopRecorderTests {
    nonisolated static let key = InputTurnHopRecorder.InputTurn(pending: .key, dispatching: false)
    /// The tests' entry image: their enqueues come through `DispatchQueue.sync`, as the hook's
    /// come through libswift_Concurrency.
    nonisolated static let dispatch = "libdispatch.dylib"

    /// Enqueues from two call sites are two rows; three from one site are one row (count 3, both
    /// origins, the priority) whose site is the calling function's frame, not the recorder's.
    @Test func enqueuesFromTwoSitesAreTwoRows() throws {
        let hops = InputTurnHopRecorder(folding: .manual, entry: Self.dispatch)
        let queue = DispatchQueue(label: "InputTurnHopRecorderTests.sync")
        for origin in [InputTurnHopRecorder.Origin.main, .offMain, .main] {
            Self.enqueueFromSiteA(hops, queue, origin: origin)
        }
        Self.enqueueFromSiteB(hops, queue)
        let snapshot = hops.snapshot(sinceLaunch: true)
        #expect(snapshot.recorded == 4)
        #expect(snapshot.rows.map(\.count) == [3, 1])
        let row = try #require(snapshot.rows.first)
        #expect(row.lane == .swift)
        #expect(row.kinds == ["key"])
        #expect(row.origin == ["main": 2, "off_main": 1])
        #expect(row.priorities == [25])
        let frame = try #require(row.frame, "the site resolves to an image + offset")
        #expect(!HopFrameResolver.runtimeImages.contains(frame.image), "the site is past the runtime")
        #expect(row.site.contains("+0x"))
        #expect(snapshot.rows.last?.frame?.image == frame.image)
        #expect(snapshot.rows.last?.site != row.site)
        #expect((1...HopRecord.depth).contains(row.stack.count))
        #expect(row.totalMilliseconds == nil)
    }

    @inline(never)
    nonisolated static func enqueueFromSiteA(_ hops: InputTurnHopRecorder, _ queue: DispatchQueue,
                                             origin: InputTurnHopRecorder.Origin) {
        queue.sync { hops.recordEnqueue(turn: key, origin: origin, priority: 25) }
    }

    @inline(never)
    nonisolated static func enqueueFromSiteB(_ hops: InputTurnHopRecorder, _ queue: DispatchQueue) {
        queue.sync { hops.recordEnqueue(turn: key, origin: .main, priority: 25) }
    }

    /// A capture in a task that resumed after an `await` follows the task's async frames (its
    /// awaiting callers), not the worker thread's frames under the resumed function.
    @Test func aCaptureInATaskFollowsItsAwaitChain() async {
        let stack = await Task.detached { await Self.outerAwait() }.value
        var resolver = ImageOffsetResolver()
        let images = stack.compactMap { resolver.resolve($0)?.image.name }
        #expect(!images.isEmpty)
        #expect(!images.contains("libsystem_pthread.dylib"), "the walk left the thread's stack for the task's: \(images)")
    }

    @inline(never)
    nonisolated static func outerAwait() async -> [UInt] {
        await innerAwait()
    }

    @inline(never)
    nonisolated static func innerAwait() async -> [UInt] {
        // Resumed by the executor: the outer function's frame is no longer on this thread's stack.
        await Task.yield()
        var record = HopRecord(lane: .swift, origin: 0, turn: key)
        record.captureStack()
        return record.stack
    }

    /// Two stacks that pass through the entry image (libdispatch) from different inner frames to one
    /// outer frame are one site: that outer frame, by image + offset. A stack with another outer
    /// frame is a second site.
    @Test func stacksMeetAtTheirFirstFramePastTheRuntime() throws {
        let runtime = try Self.symbol("dispatch_async"), outer = try Self.symbol("free"), other = try Self.symbol("realloc")
        let hops = InputTurnHopRecorder(folding: .manual, entry: Self.dispatch)
        hops.push(Self.record(stack: [try Self.symbol("malloc"), runtime, outer], turn: Self.key))
        hops.push(Self.record(stack: [try Self.symbol("calloc"), runtime, outer], turn: .init(pending: .click, dispatching: true)))
        hops.push(Self.record(stack: [try Self.symbol("malloc"), runtime, other], turn: Self.key))
        let rows = hops.snapshot(sinceLaunch: true).rows
        #expect(rows.count == 2)
        #expect(rows.first?.count == 2)
        #expect(rows.first?.kinds == ["key", "click", "dispatching"])
        #expect(rows.first?.frame?.image.hasPrefix("libsystem_malloc") == true)
        #expect(rows.first?.stack.count == 3)
        #expect(rows.first?.stack[1].image == "libdispatch.dylib")
        #expect(rows.first?.site != rows.last?.site)
    }

    /// A stack cut inside the runtime (only thread-start frames after it) or one that never came
    /// through the entry image has no site: it counts as `truncated`, never as a runtime frame.
    @Test func aStackWithNoFramePastTheRuntimeIsTruncated() throws {
        let hops = InputTurnHopRecorder(folding: .manual, entry: Self.dispatch)
        hops.push(Self.record(stack: [try Self.symbol("malloc"), try Self.symbol("dispatch_async"), try Self.symbol("pthread_create")],
                              turn: Self.key))
        hops.push(Self.record(stack: [try Self.symbol("malloc"), try Self.symbol("free")], turn: Self.key))
        let rows = hops.snapshot(sinceLaunch: true).rows
        #expect(rows.map(\.site) == ["truncated"])
        #expect(rows.first?.count == 2)
        #expect(rows.first?.frame == nil)
    }

    /// The site is the first frame past the runtime frames after the first entry frame; a stack with
    /// no entry frame, or nothing after the runtime frames, has none.
    @Test func theSiteIsTheFirstFramePastTheRuntime() {
        typealias Kind = HopFrameResolver.FrameKind
        #expect(HopFrameResolver.siteIndex([.other, .entry, .runtime, .other, .other] as [Kind]) == 3)
        #expect(HopFrameResolver.siteIndex([.runtime, .other, .entry, .other] as [Kind]) == 3, "frames before the entry are the recorder's")
        #expect(HopFrameResolver.siteIndex([.entry, .other] as [Kind]) == 1)
        #expect(HopFrameResolver.siteIndex([.other, .other] as [Kind]) == nil)
        #expect(HopFrameResolver.siteIndex([.other, .entry, .runtime] as [Kind]) == nil)
        #expect(HopFrameResolver.siteIndex([] as [Kind]) == nil)
    }

    /// The entry image, the runtime images (thread start included) and the `Task` and `MainActor`
    /// members emitted into the caller's image are never a site; an unresolved frame can be.
    @Test func framesAreKindedByImageAndSymbol() {
        let entry = HopFrameResolver.concurrencyRuntime
        #expect(HopFrameResolver.kind(Self.frame("libswift_Concurrency.dylib"), entry: entry) == .entry)
        #expect(HopFrameResolver.kind(Self.frame("libsystem_pthread.dylib"), entry: entry) == .runtime)
        #expect(HopFrameResolver.kind(Self.frame("libdispatch.dylib"), entry: entry) == .runtime)
        #expect(HopFrameResolver.kind(Self.frame("cmux DEV", symbol: "$sScTss5NeverORs_rlE8priority9operationScTyxABGScPSg_xyYaYAcntcfC"),
                                      entry: entry) == .runtime)
        #expect(HopFrameResolver.kind(Self.frame("cmux DEV", symbol: "$s9CmuxNext4ViewC6updateyyF"), entry: entry) == .other)
        #expect(HopFrameResolver.kind(nil, entry: entry) == .other)
    }

    /// A sampled callout's site is the first frame inside the innermost run-loop trampoline outside
    /// Core Foundation, Foundation, the Objective-C and Swift runtimes and libdispatch; a Swift job on
    /// the way says so; no trampoline, no site.
    @Test func aCalloutsSiteIsTheFirstFrameInsideTheTrampoline() throws {
        let timer = [Self.frame("cmux DEV"), Self.frame("cmux DEV"), Self.frame("Foundation", symbol: "__NSFireTimer"),
                     Self.frame("CoreFoundation", symbol: "__CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__"),
                     Self.frame("CoreFoundation", symbol: "__CFRunLoopDoTimer"), Self.frame("AppKit")]
        let timerSite = try #require(HopFrameResolver.calloutSite(timer))
        #expect(timerSite.index == 1 && !timerSite.swiftJob)
        let job = [Self.frame("cmux DEV"), Self.frame("libswift_Concurrency.dylib", symbol: "swift_job_run"),
                   Self.frame("libdispatch.dylib", symbol: "_dispatch_main_queue_drain"),
                   Self.frame("CoreFoundation", symbol: "__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__"),
                   Self.frame("CoreFoundation", symbol: "__CFRunLoopRun")]
        let jobSite = try #require(HopFrameResolver.calloutSite(job))
        #expect(jobSite.index == 0 && jobSite.swiftJob)
        #expect(HopFrameResolver.calloutSite([Self.frame("cmux DEV"), Self.frame("CoreFoundation", symbol: "CFRunLoopRunSpecific")]) == nil)
    }

    /// The ring holds 64 records until a fold: the rest count as dropped, and a fold frees it. The
    /// since-reset window counts only the drops after its reset.
    @Test func theRingHolds64RecordsAndCountsTheRest() throws {
        let hops = InputTurnHopRecorder(folding: .manual, entry: Self.dispatch)
        for _ in 0..<100 { hops.push(try Self.record(address: 0x10)) }
        #expect(hops.ring.count == InputTurnHopRecorder.pendingLimit)
        let snapshot = hops.snapshot(sinceLaunch: true)
        #expect(snapshot.recorded == 64)
        #expect(snapshot.dropped == 36)
        #expect(snapshot.pending == 0)
        hops.push(try Self.record(address: 0x10))
        #expect(hops.snapshot(sinceLaunch: true).recorded == 65)
        hops.reset()
        #expect(hops.snapshot(sinceLaunch: false).dropped == 0)
    }

    /// At most 128 sites: a hop at a further site counts in `sites_overflow`, a known site still counts.
    @Test func theTablesHold128Sites() throws {
        let hops = InputTurnHopRecorder(folding: .manual, entry: Self.dispatch)
        for address in 1...200 {
            hops.push(try Self.record(address: UInt(address)))
            if address % 32 == 0 { hops.fold() }
        }
        hops.push(try Self.record(address: 1))
        let snapshot = hops.snapshot(sinceLaunch: true)
        #expect(snapshot.rows.count == InputTurnHopRecorder.siteLimit)
        #expect(snapshot.sitesOverflow == 72)
        #expect(snapshot.recorded == 201)
        #expect(snapshot.rows.first?.count == 2, "the known site counted its second hop")
        #expect(snapshot.rows.first?.site == "0x1")
    }

    /// Many threads push while a fold runs: every record is folded or dropped, once.
    @Test func concurrentProducersLoseNoRecord() async throws {
        let hops = InputTurnHopRecorder(folding: .manual, entry: Self.dispatch)
        let producers = 8, each = 2_000
        let records = try (0..<producers).map { try Self.record(address: UInt($0 + 1)) }
        await withTaskGroup(of: Void.self) { group in
            for record in records {
                group.addTask {
                    for _ in 0..<each { hops.push(record) }
                }
            }
            group.addTask {
                for _ in 0..<2_000 { hops.fold() }
            }
        }
        let snapshot = hops.snapshot(sinceLaunch: true)
        #expect(snapshot.recorded + snapshot.dropped == UInt64(producers * each))
        #expect(snapshot.rows.reduce(0) { $0 + $1.count } == Int(snapshot.recorded))
        #expect(snapshot.pending == 0)
    }

    /// Reset empties the since-reset window; the since-launch window keeps every hop.
    @Test func resetStartsTheSinceResetWindowOver() throws {
        let hops = InputTurnHopRecorder(folding: .manual, entry: Self.dispatch)
        hops.push(try Self.record(address: 0x20))
        hops.reset()
        hops.push(try Self.record(address: 0x30))
        let window = hops.snapshot(sinceLaunch: false)
        #expect(window.rows.map(\.site) == ["0x30"])
        #expect(window.sinceLaunch == false)
        #expect(hops.snapshot(sinceLaunch: true).rows.count == 2)
    }

    /// A stretch is timed from its start stage to its end stage, by kind and mode, when input was
    /// pending at its start or at its end (a callout already running when the key came delays it
    /// too); one with no input at either end and one under 20 µs are not recorded.
    @Test func calloutsAreTimedWhenInputWasPendingAtEitherEnd() {
        let hops = InputTurnHopRecorder(folding: .manual)
        let fake = FakeRunLoop()
        let timer = fake.timer(hops)
        timer.observe(.entry)
        // No input at either end: not recorded.
        fake.step(timer, .afterWaiting, 2_000_000, then: .beforeTimers)
        // The key comes while a 5 ms timer callout runs: recorded.
        fake.timerDue = true
        timer.observe(.afterWaiting)
        fake.nanos += 5_000_000
        fake.turn = Self.key
        timer.observe(.beforeTimers)
        fake.timerDue = false
        // A main-queue or port wake of 1 ms, a source pass of 10 µs (not recorded).
        fake.step(timer, .afterWaiting, 1_000_000, then: .beforeTimers)
        fake.step(timer, .beforeSources, 10_000, then: .beforeWaiting)
        let rows = Dictionary(uniqueKeysWithValues: hops.snapshot(sinceLaunch: true).rows.map { ($0.site, $0) })
        #expect(rows.count == 2)
        #expect(rows["runloop.timer"]?.totalMilliseconds == 5)
        #expect(rows["runloop.timer"]?.callouts == ["timer"])
        #expect(rows["runloop.timer"]?.includesSwiftJobs == false)
        #expect(rows["runloop.main_queue_or_port"]?.totalMilliseconds == 1)
        #expect(rows["runloop.main_queue_or_port"]?.origin == ["default": 1])
        #expect(rows["runloop.main_queue_or_port"]?.includesSwiftJobs == true)
        #expect(rows.values.allSatisfy { $0.lane == .nonswift && $0.kinds == ["key"] })
    }

    /// A nested run loop inside a callout (a menu) in CFRunLoop's real stage order: its first
    /// `beforeTimers` meets the outer stretch at another depth, which is not recorded; the inner
    /// stretch is, at its own depth and mode.
    @Test func aNestedRunLoopTimesOnlyItsOwnStretch() {
        let hops = InputTurnHopRecorder(folding: .manual)
        let fake = FakeRunLoop()
        fake.turn = Self.key
        let timer = fake.timer(hops)
        timer.observe(.entry)
        timer.observe(.beforeTimers)
        timer.observe(.beforeSources)
        fake.nanos += 4_000_000
        fake.mode = .eventTracking
        timer.observe(.entry)
        timer.observe(.beforeTimers)
        fake.step(timer, .beforeSources, 500_000, then: .exit)
        fake.nanos += 4_000_000
        fake.mode = .default
        timer.observe(.beforeWaiting)
        let rows = hops.snapshot(sinceLaunch: true).rows
        #expect(rows.count == 1)
        #expect(rows.first?.site == "runloop.sources_or_polled_main_queue")
        #expect(rows.first?.count == 1)
        #expect(rows.first?.origin == ["event_tracking": 1])
        #expect(rows.first?.totalMilliseconds == 0.5)
    }

    /// The end of a stretch that left records wakes the fold once, on its queue (never the main
    /// thread), the end of a pass that CFRunLoop's poll sent from the sources back to the timers
    /// with no wait included.
    @Test func aPassWithNoWaitWakesTheFoldOffMain() async {
        let queue = DispatchQueue(label: "InputTurnHopRecorderTests.fold")
        let hops = InputTurnHopRecorder(folding: .queue(queue))
        let fake = FakeRunLoop()
        fake.turn = Self.key
        let timer = fake.timer(hops)
        timer.observe(.entry)
        fake.step(timer, .beforeSources, 1_000_000, then: .beforeTimers)
        await Self.flush(queue)
        #expect(hops.ring.count == 0, "the woken fold took the record")
        #expect(hops.snapshot(sinceLaunch: true).recorded == 1)
    }

    /// A long callout in an input turn is sampled while it runs and counts under its site, with the
    /// sample's frames up to the site; one whose sample came after its end counts under its stretch;
    /// one far from any input is not armed. The deadline sleeps on the injected clock.
    @Test func aSampledCalloutCountsUnderItsSite() async throws {
        let stack = [try Self.symbol("malloc"), try Self.symbol("free"), try Self.symbol("realloc")]
        let clock = ManualClock()
        let samples = HopWord()
        let sampler = CalloutStackSampler(thresholdNanos: 2_000_000, clock: clock, findSite: { _ in (index: 1, swiftJob: true) }) {
            samples.value.add(1, ordering: .relaxed)
            return stack
        }
        let hops = InputTurnHopRecorder(folding: .manual)
        let fake = FakeRunLoop()
        let timer = fake.timer(hops, sampler: sampler)
        timer.observe(.entry)
        // Far from any input: not armed, not recorded.
        fake.step(timer, .afterWaiting, 3_000_000, then: .beforeTimers)
        #expect(clock.sleeperCount == 0)
        fake.turn = Self.key
        // Armed at its start (generation 1): its deadline sleeps on the clock; sampled while it runs.
        timer.observe(.afterWaiting)
        try await clock.waitForSleeper()
        sampler.take(1)
        fake.nanos += 3_000_000
        timer.observe(.beforeTimers)
        // Generation 2 ends before its sample: the late sample finds it closed and publishes nothing.
        fake.step(timer, .beforeSources, 2_000_000, then: .beforeTimers)
        sampler.take(2)
        let rows = Dictionary(uniqueKeysWithValues: hops.snapshot(sinceLaunch: true).rows.map { ($0.site, $0) })
        #expect(samples.value.load(ordering: .relaxed) == 1)
        #expect(rows.count == 2)
        let sampled = try #require(rows.values.first { $0.frame != nil })
        #expect(sampled.lane == .nonswift)
        #expect(sampled.frame?.image.hasPrefix("libsystem_malloc") == true)
        #expect(sampled.stack.count == 2, "the frames up to the site")
        #expect(sampled.callouts == ["main_queue_or_port"])
        #expect(sampled.includesSwiftJobs == true)
        #expect(sampled.totalMilliseconds == 3)
        #expect(rows["runloop.sources_or_polled_main_queue"]?.totalMilliseconds == 2)
    }

    /// The rows encode with the `debug.input hops` keys: site, lane swift|nonswift, count, kinds, origin.
    @Test func rowsEncodeWithTheirKeys() throws {
        let hops = InputTurnHopRecorder(folding: .manual, entry: Self.dispatch)
        hops.push(try Self.record(address: 0x40))
        hops.recordCallout(.timer, mode: .default, turn: Self.key, nanos: 2_000_000)
        let data = try JSONEncoder().encode(hops.snapshot(sinceLaunch: true))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["since_launch", "recorded", "dropped", "sites_overflow", "pending", "rows"])
        let rows = try #require(object["rows"] as? [[String: Any]])
        #expect(Set(rows.compactMap { $0["lane"] as? String }) == ["swift", "nonswift"])
        for row in rows {
            #expect(row["site"] is String && row["count"] is Int && row["kinds"] is [String] && row["origin"] is [String: Int])
        }
        let nonswift = try #require(rows.first { $0["lane"] as? String == "nonswift" })
        #expect(nonswift["total_ms"] as? Double == 2)
        #expect(nonswift["callouts"] as? [String] == ["timer"])
        #expect(nonswift["includes_swift_jobs"] as? Bool == false)
    }

    /// A Swift record that came through libdispatch from `address` (not in any image: an
    /// unresolved site).
    nonisolated static func record(address: UInt) throws -> HopRecord {
        record(stack: [try symbol("dispatch_async"), address], turn: key)
    }

    nonisolated static func record(stack: [UInt], turn: InputTurnHopRecorder.InputTurn) -> HopRecord {
        var record = HopRecord(lane: .swift, origin: InputTurnHopRecorder.Origin.main.rawValue, turn: turn)
        record.setStack(stack)
        return record
    }

    /// A resolved frame of `image`.
    nonisolated static func frame(_ image: String, symbol: String? = nil) -> ImageOffsetResolver.Resolved {
        ImageOffsetResolver.Resolved(base: 0x1000, image: .init(name: image, uuid: nil), offset: 0x10, nearestSymbol: symbol)
    }

    /// A return address inside the exported function `name` (past its first instruction).
    nonisolated static func symbol(_ name: String) throws -> UInt {
        let address = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), name), "dlsym \(name)")
        return UInt(bitPattern: address) + 8
    }

    /// Returns once every block queued on `queue` before it ran.
    static func flush(_ queue: DispatchQueue) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
    }
}

/// A run loop's clock, timer state, mode and input turn, for ``InputTurnCalloutTimer``.
@MainActor
private final class FakeRunLoop {
    var nanos: UInt64 = 1_000_000_000
    var timerDue = false
    var mode = InputTurnHopRecorder.RunLoopModeName.default
    var turn = InputTurnHopRecorder.InputTurn()

    /// A timer that reads this run loop and observes nothing (the test drives its stages).
    func timer(_ hops: InputTurnHopRecorder, sampler: CalloutStackSampler? = nil) -> InputTurnCalloutTimer {
        InputTurnCalloutTimer(diagnostics: hops, sampler: sampler, observing: false, now: { self.nanos }, timerDue: { self.timerDue },
                              mode: { self.mode }) { self.turn }
    }

    /// `start`, then `nanos` later `end`.
    func step(_ timer: InputTurnCalloutTimer, _ start: CFRunLoopActivity, _ duration: UInt64, then end: CFRunLoopActivity) {
        timer.observe(start)
        nanos += duration
        timer.observe(end)
    }
}
#endif
