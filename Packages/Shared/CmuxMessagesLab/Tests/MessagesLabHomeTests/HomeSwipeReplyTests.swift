import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Lawrence, 2026-11-20: "using two fingers to swipe on home chief imessage messages fails to reply it",
/// then "i can see the two swip kinda work but not perfectly work". The bubble moved with the fingers,
/// but the reply did not come reliably. The swipe's event monitor returned `handle(e) ?? e`, so every
/// event it had taken (nil) still went on to the transcript's scroll view. The scroll view also scrolled
/// the gesture, and its responsive scrolling could take the rest of the gesture away from the monitor,
/// so the release never arrived. A diagonal or leftward scroll that started on a bubble was taken
/// as a swipe and lost its scroll. After a slow swipe with no momentum, the next scroll lost its momentum.
///
/// Each test feeds a phased trackpad stream (may-begin, began, changed, ended, then momentum) to the
/// pane's monitor path (`SwipeReply.monitored`), on the newest Chief bubble of the real Home view over
/// a real `HomeStore` (`HomeChatRig`). A nil result means the event was taken and the scroll view never
/// gets it.
@MainActor @Suite(.serialized) struct HomeSwipeReplyTests {
    /// Scroll phases (`CGScrollPhase`) and momentum phases (`CGMomentumScrollPhase`).
    enum Phase: Int64 { case mayBegin = 128, began = 1, changed = 2, ended = 4, cancelled = 8 }
    enum Momentum: Int64 { case began = 1, changed = 2, ended = 3 }

    /// One phased scroll event at `t` seconds. Positive `dx` is a swipe to the right (as the trackpad
    /// reports it with natural scrolling).
    static func event(dx: CGFloat = 0, dy: CGFloat = 0, phase: Phase? = nil, momentum: Momentum? = nil, t: TimeInterval) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase?.rawValue ?? 0)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum?.rawValue ?? 0)
        // `NSEvent.timestamp` reads a CGEvent's time as nanoseconds since startup.
        cg.timestamp = CGEventTimestamp((1_000 + t) * 1e9)
        return try #require(NSEvent(cgEvent: cg))
    }

    /// The rig and the middle of its newest Chief bubble (host points).
    private func rig() async throws -> (HomeChatRig, ChatController, CGPoint) {
        let r = try await HomeChatRig(history: 12)
        for _ in 0..<4 { r.frame() }
        let c = r.view.controller
        let demo = try #require(c.demo)
        let hit = try #require(demo.lastTextRow(mine: false), "no Chief bubble in the transcript")
        let p = CGPoint(x: hit.body.midX, y: hit.body.midY)
        try #require(demo.hit(p) != nil, "the newest Chief bubble is not on screen")
        return (r, c, p)
    }

    /// Feeds a stream to the pane's monitor; returns which events reached the scroll view.
    @discardableResult
    private func feed(_ c: ChatController, _ p: CGPoint, _ events: [NSEvent]) -> [Bool] {
        events.map { c.swipe.monitored($0, at: p) != nil }
    }

    /// A two-finger swipe: fingers down, `total` (dx, dy) in `steps` changes `dt` apart, release.
    private func swipe(dx: CGFloat, dy: CGFloat = 0, steps: Int, dt: TimeInterval = 1.0 / 120, from t0: TimeInterval = 0,
                       release: Phase = .ended, releaseAfter: TimeInterval? = nil) throws -> [NSEvent] {
        var out = [try Self.event(phase: .mayBegin, t: t0)]
        let sx = dx / CGFloat(steps), sy = dy / CGFloat(steps)
        for i in 0..<steps {
            out.append(try Self.event(dx: sx, dy: sy, phase: i == 0 ? .began : .changed, t: t0 + dt * Double(i + 1)))
        }
        out.append(try Self.event(phase: release, t: t0 + dt * Double(steps) + (releaseAfter ?? dt)))
        return out
    }

    private func openThread(_ c: ChatController) -> String? { c.store?.state.ui.openThread?.messageId }

    @Test func aClaimedSwipeNeverReachesTheScrollView() async throws {
        let (r, c, p) = try await rig()
        defer { r.stop() }
        let passed = feed(c, p, try swipe(dx: 160, steps: 16))
        #expect(passed.allSatisfy { !$0 }, "events of a claimed swipe that went on to the scroll view: \(passed)")
        #expect(openThread(c) != nil, "a full swipe opens the reply")
    }

    @Test func aFullSwipeOpensTheReplyAndTheRowGoesBack() async throws {
        let (r, c, p) = try await rig()
        defer { r.stop() }
        let events = try swipe(dx: 160, steps: 16)
        var peak: CGFloat = 0
        for e in events.dropLast() { _ = c.swipe.monitored(e, at: p); peak = max(peak, c.swipe.rowOffset) }
        #expect(peak > 40 && peak <= SwipeReply.Tuning.maxOffset, "peak row offset \(peak)")
        _ = c.swipe.monitored(try #require(events.last), at: p)
        #expect(openThread(c) != nil)
        #expect(c.swipe.rowOffset == 0, "the row's model offset after release is \(c.swipe.rowOffset)")
    }

    @Test func aShortSwipeWaitsForTheSlopThenSpringsBackWithoutAReply() async throws {
        let (r, c, p) = try await rig()
        defer { r.stop() }
        // Real Messages (swipe-partial, 120 Hz): 40 pt in 0.3 s, held 0.3 s, released. The row stays
        // still for the first 15 pt of travel, then follows 1:1.
        let events = try swipe(dx: 40, steps: 8, dt: 0.3 / 8, releaseAfter: 0.3)
        var offsets: [CGFloat] = []
        for e in events.dropLast() { _ = c.swipe.monitored(e, at: p); offsets.append(c.swipe.rowOffset) }
        #expect(offsets.dropFirst(2).first == 0, "row offset after 10 pt of travel: \(offsets)")
        #expect(abs((offsets.last ?? 0) - 25) < 0.5, "row offset after 40 pt of travel: \(offsets.last ?? -1)")
        _ = c.swipe.monitored(try #require(events.last), at: p)
        #expect(openThread(c) == nil, "a 40 pt swipe released slowly opened the reply")
        #expect(c.swipe.rowOffset == 0)
    }

    @Test func aDiagonalScrollOnABubbleStaysAScroll() async throws {
        let (r, c, p) = try await rig()
        defer { r.stop() }
        // 40 degrees off horizontal: a scroll that drifted, not a swipe.
        let passed = feed(c, p, try swipe(dx: 120, dy: -100, steps: 12))
        #expect(passed.dropFirst(2).allSatisfy { $0 }, "a diagonal scroll was taken: \(passed)")
        #expect(openThread(c) == nil)
        #expect(c.swipe.rowOffset == 0)
    }

    /// Fleet capture, 2026-11-21: right after a swipe, the 100 x 90 diagonal was taken as one. The
    /// swipe's held motion (summed until its direction is known) stayed from the last gesture, so the
    /// next one started 10 pt to the right.
    @Test func aDiagonalRightAfterASwipeStaysAScroll() async throws {
        let (r, c, p) = try await rig()
        defer { r.stop() }
        feed(c, p, try swipe(dx: 160, steps: 16))
        c.dispatch(.closeThread)
        r.frame()
        let passed = feed(c, p, try swipe(dx: 100, dy: 90, steps: 25, from: 2))
        #expect(passed.dropFirst(2).allSatisfy { $0 }, "a diagonal after a swipe was taken: \(passed)")
        #expect(openThread(c) == nil)
        #expect(c.swipe.rowOffset == 0)
    }

    @Test func aLeftwardSwipeOnABubbleStaysAScroll() async throws {
        let (r, c, p) = try await rig()
        defer { r.stop() }
        let passed = feed(c, p, try swipe(dx: -160, steps: 16))
        #expect(passed.dropFirst(2).allSatisfy { $0 }, "a leftward swipe was taken: \(passed)")
        #expect(openThread(c) == nil)
    }

    @Test func theNextScrollKeepsItsMomentumAfterASlowSwipe() async throws {
        let (r, c, p) = try await rig()
        defer { r.stop() }
        // A slow swipe released at rest: no momentum follows it.
        feed(c, p, try swipe(dx: 40, steps: 8, releaseAfter: 0.3))
        // Then a vertical fling, with its momentum.
        var fling = try swipe(dx: 0, dy: -200, steps: 10, from: 2)
        let momentum = [try Self.event(dy: -30, momentum: .began, t: 2.2), try Self.event(dy: -20, momentum: .changed, t: 2.21),
                        try Self.event(momentum: .ended, t: 2.3)]
        fling += momentum
        let passed = feed(c, p, fling)
        #expect(passed.suffix(3).allSatisfy { $0 }, "the fling's momentum was swallowed: \(passed.suffix(3))")
    }

    @Test func theSwipesOwnMomentumIsSwallowed() async throws {
        let (r, c, p) = try await rig()
        defer { r.stop() }
        feed(c, p, try swipe(dx: 160, steps: 8))
        let passed = feed(c, p, [try Self.event(dx: 30, momentum: .began, t: 0.1), try Self.event(dx: 20, momentum: .changed, t: 0.11),
                                 try Self.event(momentum: .ended, t: 0.2)])
        #expect(passed.allSatisfy { !$0 }, "the swipe's momentum went on to the scroll view: \(passed)")
    }

    @Test func aQuickFlickPastTheSlopOpensTheReply() async throws {
        let (r, c, p) = try await rig()
        defer { r.stop() }
        // 45 pt in 4 frames (1350 pt/s), lifted while still moving: short of the 60 pt threshold.
        let events = try swipe(dx: 45, steps: 4)
        #expect(abs((events[2].timestamp - events[1].timestamp) - 1.0 / 120) < 1e-4, "event times: \(events.map(\.timestamp))")
        feed(c, p, events)
        #expect(openThread(c) != nil, "a flick released at speed did not open the reply")
    }

    @Test func aCancelledSwipeOpensNothing() async throws {
        let (r, c, p) = try await rig()
        defer { r.stop() }
        feed(c, p, try swipe(dx: 160, steps: 16, release: .cancelled))
        #expect(openThread(c) == nil)
        #expect(c.swipe.rowOffset == 0)
    }

    @Test func fingersDownOutsideTheTranscriptAreNotHeld() async throws {
        let (r, c, p) = try await rig()
        defer { r.stop() }
        let outside = CGPoint(x: c.host.bounds.maxX + 40, y: p.y)
        let passed = try swipe(dx: 160, steps: 16).map { c.swipe.monitored($0, at: outside) != nil }
        #expect(passed.allSatisfy { $0 }, "a gesture outside this pane was held or taken: \(passed)")
    }

    /// The swiped rows that are going back to rest (the return animation is on).
    private func returning(_ c: ChatController) -> Int {
        (c.demo?.collection.visibleCells ?? []).filter { $0.layer.animation(forKey: "swipe.back") != nil }.count
    }

    @Test func theRowGoesBackWithMessagesReturnAndWithoutOneUnderReduceMotion() async throws {
        let (r, c, p) = try await rig()
        defer { r.stop() }
        c.swipe.reduceMotion = { false }
        feed(c, p, try swipe(dx: 40, steps: 8, dt: 0.3 / 8, releaseAfter: 0.3))
        #expect(returning(c) == 1, "no row runs the return after a swipe")
        c.swipe.reduceMotion = { true }
        feed(c, p, try swipe(dx: 40, steps: 8, dt: 0.3 / 8, from: 2, releaseAfter: 0.3))
        #expect(returning(c) == 0, "Reduce Motion: the row still animates back")
        #expect(c.swipe.rowOffset == 0)
    }

    /// The capture's player (`debug.home.drive` `swipe`, TrackpadSwipePlayer) on the newest Chief
    /// bubble, stepped at `hz` through the swipe's monitor path; returns every event it sent. With
    /// `reenter`, the first event the swipe leaves runs the next frame from inside its delivery, as a
    /// scroll view tracking a phased gesture in its own run loop lets the display link do.
    private func play(_ r: HomeChatRig, _ c: ChatController, _ p: CGPoint, dx: CGFloat, dy: CGFloat = 0,
                      duration: TimeInterval, hz: Double, reenter: Bool = false) -> [NSEvent] {
        var sent: [NSEvent] = []
        var frame = 1
        var reentered = false
        var holder: TrackpadSwipePlayer?
        let player = TrackpadSwipePlayer(point: p, dx: dx, dy: dy, duration: duration, hold: 0, window: r.window) { e in
            sent.append(e)
            if c.swipe.monitored(e, at: p) != nil, reenter, !reentered {
                reentered = true
                frame += 1
                holder?.advance(to: Double(frame) / hz)
            }
            return "monitor"
        }
        holder = player
        player.begin()
        while !player.advance(to: Double(frame) / hz) { frame += 1 }
        return sent
    }

    /// The fleet capture's diagonal (100 pt right, 90 pt up or down), at 60 and 120 Hz, entered again
    /// from inside its delivery. The player once sent the gesture's start a second time from there: the
    /// capture showed the diagonal claimed as a swipe.
    @Test(arguments: [60.0, 120.0], [-90.0, 90.0])
    func thePlayersDiagonalStaysAScroll(hz: Double, dy: Double) async throws {
        let (r, c, p) = try await rig()
        defer { r.stop() }
        let sent = play(r, c, p, dx: 100, dy: dy, duration: 0.4, hz: hz, reenter: true)
        #expect(sent.filter { $0.phase.contains(.began) }.count == 1, "starts sent: \(sent.map(\.phase.rawValue))")
        #expect(sent.reduce(0) { $0 + $1.scrollingDeltaX } == 100 && sent.reduce(0) { $0 + $1.scrollingDeltaY } == dy,
                "the steps do not add up to the path")
        #expect(openThread(c) == nil, "the player's diagonal (dy \(dy)) opened the reply at \(hz) Hz")
        #expect(c.swipe.rowOffset == 0)
    }

    @Test(arguments: [60.0, 120.0])
    func thePlayersFullSwipeOpensTheReply(hz: Double) async throws {
        let (r, c, p) = try await rig()
        defer { r.stop() }
        _ = play(r, c, p, dx: 160, duration: 0.35, hz: hz)
        #expect(openThread(c) != nil, "the player's full swipe did not open the reply at \(hz) Hz")
    }
}
