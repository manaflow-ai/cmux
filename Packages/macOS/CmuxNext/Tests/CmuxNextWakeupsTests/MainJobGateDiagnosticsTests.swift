#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import Dispatch
import Darwin
import Foundation
import Testing
@testable import CmuxNextWakeups

/// The input-turn hop recorder (plans/cmux-next/chrome-parity/p04-input.md, task 022): hops from one
/// call site fold into one row with their count, kinds and origins; the site is the first frame
/// after the runtime frames; the ring holds 64 records and the tables 128 sites; non-Swift
/// callouts are timed only in input turns and at their own run-loop depth; reset starts the
/// since-reset window over; the rows encode as `debug.input hops` returns them.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainJobGateDiagnosticsTests {
    nonisolated static let key = MainJobGateDiagnostics.InputTurn(pending: .key, dispatching: false)

    /// Three enqueues from one line are one row (count 3, both origins, the priority), whose site is
    /// a resolved frame of this test binary and whose stack is at most 8 frames.
    @Test func enqueuesFromOneSiteAreOneRow() throws {
        let hops = MainJobGateDiagnostics(folding: .manual)
        for origin in [MainJobGateDiagnostics.Origin.main, .offMain, .main] {
            hops.recordEnqueue(turn: Self.key, origin: origin, priority: 25)
        }
        let snapshot = hops.snapshot(sinceLaunch: true)
        #expect(snapshot.recorded == 3)
        #expect(snapshot.rows.count == 1)
        let row = try #require(snapshot.rows.first)
        #expect(row.count == 3)
        #expect(row.lane == .swift)
        #expect(row.kinds == ["key"])
        #expect(row.origin == ["main": 2, "off_main": 1])
        #expect(row.priorities == [25])
        #expect(row.frame != nil, "the site resolves to an image + offset")
        #expect(row.site.contains("+0x"))
        #expect((1...HopRecord.depth).contains(row.stack.count))
        #expect(row.totalMilliseconds == nil)
    }

    /// Two stacks that pass through the runtime (libdispatch) from different inner frames to one
    /// outer frame are one site: that outer frame, by image + offset. A stack with another outer
    /// frame is a second site.
    @Test func stacksMeetAtTheirFirstFramePastTheRuntime() throws {
        let runtime = try Self.symbol("dispatch_async"), outer = try Self.symbol("free"), other = try Self.symbol("realloc")
        let hops = MainJobGateDiagnostics(folding: .manual)
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

    /// The site is the first frame past the runtime frames the enqueue went through; with no runtime
    /// frame it is the innermost frame.
    @Test func theSiteIsTheFirstFramePastTheRuntime() {
        #expect(HopFrameResolver.siteIndex([false, true, true, false, false]) == 3)
        #expect(HopFrameResolver.siteIndex([false, nil, true, nil, false]) == 3)
        #expect(HopFrameResolver.siteIndex([false, false]) == 0)
        #expect(HopFrameResolver.siteIndex([true, true]) == 1)
        #expect(HopFrameResolver.siteIndex([]) == nil)
    }

    /// The ring holds 64 records until a fold: the rest count as dropped, and a fold frees it.
    @Test func theRingHolds64RecordsAndCountsTheRest() {
        let hops = MainJobGateDiagnostics(folding: .manual)
        for _ in 0..<100 { hops.push(Self.record(address: 0x10)) }
        #expect(hops.ring.count == MainJobGateDiagnostics.pendingLimit)
        let snapshot = hops.snapshot(sinceLaunch: true)
        #expect(snapshot.recorded == 64)
        #expect(snapshot.dropped == 36)
        #expect(snapshot.pending == 0)
        hops.push(Self.record(address: 0x10))
        #expect(hops.snapshot(sinceLaunch: true).recorded == 65)
    }

    /// At most 128 sites: a hop at a further site counts in `sites_overflow`, a known site still counts.
    @Test func theTablesHold128Sites() {
        let hops = MainJobGateDiagnostics(folding: .manual)
        for address in 1...200 {
            hops.push(Self.record(address: UInt(address)))
            if address % 32 == 0 { hops.fold() }
        }
        hops.push(Self.record(address: 1))
        let snapshot = hops.snapshot(sinceLaunch: true)
        #expect(snapshot.rows.count == MainJobGateDiagnostics.siteLimit)
        #expect(snapshot.sitesOverflow == 72)
        #expect(snapshot.recorded == 201)
        #expect(snapshot.rows.first?.count == 2, "the known site counted its second hop")
        #expect(snapshot.rows.first?.site == "0x1")
    }

    /// Many threads push while a fold runs: every record is folded or dropped, once.
    @Test func concurrentProducersLoseNoRecord() async {
        let hops = MainJobGateDiagnostics(folding: .manual)
        let producers = 8, each = 2_000
        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<producers {
                group.addTask {
                    for _ in 0..<each { hops.push(Self.record(address: UInt(producer + 1))) }
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
    @Test func resetStartsTheSinceResetWindowOver() {
        let hops = MainJobGateDiagnostics(folding: .manual)
        hops.push(Self.record(address: 0x20))
        hops.reset()
        hops.push(Self.record(address: 0x30))
        let window = hops.snapshot(sinceLaunch: false)
        #expect(window.rows.map(\.site) == ["0x30"])
        #expect(window.sinceLaunch == false)
        #expect(hops.snapshot(sinceLaunch: true).rows.count == 2)
    }

    /// A callout in an input turn is timed from its start stage to its end stage, by kind and mode;
    /// one outside input, one under 20 µs and one that a nested run loop interrupted are not.
    @Test func calloutsAreTimedOnlyInInputTurns() {
        let hops = MainJobGateDiagnostics(folding: .manual)
        let fake = FakeRunLoop()
        let timer = InputTurnCalloutTimer(diagnostics: hops, observing: false, now: { fake.nanos }, timerDue: { fake.timerDue },
                                          mode: { fake.mode }) { fake.turn }
        timer.observe(.entry)
        // No input: not timed.
        fake.step(timer, .afterWaiting, 2_000_000, then: .beforeTimers)
        fake.turn = Self.key
        // A main-queue or port wake of 1 ms, a timer wake of 3 ms, a source pass of 10 µs (not recorded).
        fake.step(timer, .afterWaiting, 1_000_000, then: .beforeTimers)
        fake.timerDue = true
        fake.step(timer, .afterWaiting, 3_000_000, then: .beforeTimers)
        fake.step(timer, .beforeSources, 10_000, then: .beforeWaiting)
        // A nested run loop inside the callout (a menu): the outer stretch is not timed, the inner one is.
        fake.mode = .eventTracking
        timer.observe(.beforeSources)
        timer.observe(.entry)
        fake.step(timer, .beforeSources, 500_000, then: .exit)
        fake.nanos += 4_000_000
        timer.observe(.beforeWaiting)
        let rows = Dictionary(uniqueKeysWithValues: hops.snapshot(sinceLaunch: true).rows.map { ($0.site, $0) })
        #expect(rows.count == 3)
        #expect(rows["runloop.main_queue_or_port"]?.totalMilliseconds == 1)
        #expect(rows["runloop.main_queue_or_port"]?.origin == ["default": 1])
        #expect(rows["runloop.timer"]?.maxMilliseconds == 3)
        #expect(rows["runloop.sources"]?.count == 1)
        #expect(rows["runloop.sources"]?.origin == ["event_tracking": 1])
        #expect(rows["runloop.sources"]?.totalMilliseconds == 0.5)
        #expect(rows.values.allSatisfy { $0.lane == .nonswift && $0.kinds == ["key"] })
    }

    /// The end of a turn that left records wakes the fold once, on its queue (never the main thread).
    @Test func theTurnEndWakesTheFoldOffMain() async {
        let queue = DispatchQueue(label: "MainJobGateDiagnosticsTests.fold")
        let hops = MainJobGateDiagnostics(folding: .queue(queue))
        let fake = FakeRunLoop()
        fake.turn = Self.key
        let timer = InputTurnCalloutTimer(diagnostics: hops, observing: false, now: { fake.nanos }, timerDue: { false },
                                          mode: { .default }) { fake.turn }
        timer.observe(.entry)
        fake.step(timer, .afterWaiting, 1_000_000, then: .beforeWaiting)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
        #expect(hops.ring.count == 0, "the woken fold took the record")
        #expect(hops.snapshot(sinceLaunch: true).recorded == 1)
    }

    /// The rows encode with the `debug.input hops` keys: site, lane swift|nonswift, count, kinds, origin.
    @Test func rowsEncodeWithTheirKeys() throws {
        let hops = MainJobGateDiagnostics(folding: .manual)
        hops.push(Self.record(address: 0x40))
        hops.recordCallout(.timer, mode: .default, turn: Self.key, nanos: 2_000_000)
        let data = try JSONEncoder().encode(hops.snapshot(sinceLaunch: true))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["since_launch", "recorded", "dropped", "sites_overflow", "pending", "rows"])
        let rows = try #require(object["rows"] as? [[String: Any]])
        #expect(Set(rows.compactMap { $0["lane"] as? String }) == ["swift", "nonswift"])
        for row in rows {
            #expect(row["site"] is String && row["count"] is Int && row["kinds"] is [String] && row["origin"] is [String: Int])
        }
        #expect(rows.first { $0["lane"] as? String == "nonswift" }?["total_ms"] as? Double == 2)
    }

    /// A Swift record whose one frame is `address` (not in any image: an unresolved site).
    nonisolated static func record(address: UInt) -> HopRecord {
        record(stack: [address], turn: key)
    }

    nonisolated static func record(stack: [UInt], turn: MainJobGateDiagnostics.InputTurn) -> HopRecord {
        var record = HopRecord(lane: .swift, origin: MainJobGateDiagnostics.Origin.main.rawValue, turn: turn)
        record.setStack(stack)
        return record
    }

    /// A return address inside the exported function `name` (past its first instruction).
    static func symbol(_ name: String) throws -> UInt {
        let address = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), name), "dlsym \(name)")
        return UInt(bitPattern: address) + 8
    }
}

/// A run loop's clock, timer state, mode and input turn, for ``InputTurnCalloutTimer``.
@MainActor
private final class FakeRunLoop {
    var nanos: UInt64 = 1_000_000_000
    var timerDue = false
    var mode = MainJobGateDiagnostics.RunLoopModeName.default
    var turn = MainJobGateDiagnostics.InputTurn()

    /// `start`, then `nanos` later `end`.
    func step(_ timer: InputTurnCalloutTimer, _ start: CFRunLoopActivity, _ duration: UInt64, then end: CFRunLoopActivity) {
        timer.observe(start)
        nanos += duration
        timer.observe(end)
    }
}
#endif
