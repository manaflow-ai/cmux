import AppKit
import CmuxNextCompat
@testable import CmuxNextPages
import CmuxNextWakeups
import CoreGraphics
import Foundation
import QuartzCore
import Testing

/// ``PagePreloadSlot`` holds at most one page, parks it in Chrome's order (visible load, cover,
/// hidden, then frozen), refits it once per quiet size, claims it in the open's turn with its cover
/// on top only at the size the cover shows and no implicit animation, takes the cover off at the
/// first live frame or its limit, and drops it on any non-normal pressure (the host's
/// memory registration is `WebUIHostPressureTests`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PagePreloadSlotTests {
    /// A page that logs each call and holds its paint and cover callbacks until the test fires them.
    @MainActor final class FakePage: PreloadablePage {
        let name: String
        let preloadView = NSView(frame: .zero)
        /// Whether the engine takes a freeze (false: a fork before SetPageFrozen).
        let freezes: Bool
        var calls: [String] = []
        var paintWaiters: [@MainActor () -> Void] = []
        var coverWaiters: [@MainActor (CGImage?) -> Void] = []
        var closed = false
        var claimed = false
        /// A call the slot made after the page was claimed or closed that only a held page may get.
        var lateCalls: [String] = []

        init(_ name: String, freezes: Bool = true) {
            self.name = name
            self.freezes = freezes
        }

        var preloadTraceID: UInt64 { UInt64(UInt(bitPattern: ObjectIdentifier(self))) }

        func preloadWhenPainted(_ body: @escaping @MainActor () -> Void) {
            calls.append("whenPainted")
            paintWaiters.append(body)
        }

        func preloadCaptureCover(_ body: @escaping @MainActor (CGImage?) -> Void) {
            note("capture")
            coverWaiters.append(body)
        }

        func preloadSetVisible(_ visible: Bool) { note(visible ? "visible" : "hidden") }

        func preloadFreeze() -> Bool {
            note("freeze")
            return freezes
        }

        func preloadThaw() { note("thaw") }

        func close() {
            note("close")
            closed = true
        }

        private func note(_ call: String) {
            calls.append(call)
            if claimed || closed { lateCalls.append(call) }
        }

        /// Fires the waiting paint callbacks (as the engine's next frame would).
        func paint() {
            let waiters = paintWaiters
            paintWaiters = []
            for waiter in waiters { waiter() }
        }

        /// Hands the waiting cover callbacks a picture.
        func cover(_ image: CGImage? = PagePreloadSlotTests.image()) {
            let waiters = coverWaiters
            coverWaiters = []
            for waiter in waiters { waiter(image) }
        }

        /// The calls that tell the engine something (not the waits).
        var moves: [String] { calls.filter { $0 != "whenPainted" } }
        func count(_ move: String) -> Int { calls.filter { $0 == move }.count }
    }

    @MainActor final class FakeParking: PreloadParking {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        var holds: [NSSize] = []

        func hold(_ held: NSView, at size: NSSize) {
            holds.append(size)
            if held.superview !== view { view.addSubview(held) }
            held.frame = NSRect(origin: .zero, size: size)
        }
    }

    static func image() -> CGImage? {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context?.makeImage()
    }

    static let newTab = PagePreloadSlot.Key("newTab")
    static let settings = PagePreloadSlot.Key("settings")
    static let size = NSSize(width: 800, height: 600)
    static let bigger = NSSize(width: 1_000, height: 700)

    /// The slot's deadlines on a wake-up queue only the test fires.
    private let rig = LifecycleDeadlineRig()

    private func makeSlot(_ state: PagePreloadSlot.ParkState = .frozenHidden,
                          moves: ((PagePreloadSlot.Move, UInt64) -> Void)? = nil) -> PagePreloadSlot {
        PagePreloadSlot(parkState: state, deadlines: rig.scheduler) { move, page in moves?(move, page) }
    }

    /// Preloads `page` and walks it to parked.
    private func park(_ page: FakePage, in slot: PagePreloadSlot, key: PagePreloadSlot.Key = PagePreloadSlotTests.newTab,
                      parking: any PreloadParking, size: NSSize = PagePreloadSlotTests.size) {
        slot.preload(key, size: size, in: parking) { _ in page }
        page.paint()
        page.cover()
    }

    // MARK: Park

    @Test func parksVisibleThenHiddenThenFrozen() {
        let slot = makeSlot()
        let parking = FakeParking()
        let page = FakePage("a")
        #expect(slot.preload(Self.newTab, size: Self.size, in: parking) { _ in page })
        #expect(slot.phase == .loading)
        #expect(page.preloadView.superview === parking.view)
        #expect(parking.holds == [Self.size])
        #expect(page.moves == ["visible"])
        page.paint()
        #expect(slot.phase == .capturing)
        page.cover()
        #expect(slot.phase == .parked)
        #expect(slot.isFrozen)
        // Loaded visible, cover taken while visible, then hidden before frozen.
        #expect(page.moves == ["visible", "capture", "hidden", "freeze"])
    }

    @Test func renderedParkHidesWithoutFreezing() {
        let slot = makeSlot(.renderedParked)
        let page = FakePage("a")
        park(page, in: slot, parking: FakeParking())
        #expect(slot.phase == .parked)
        #expect(!slot.isFrozen)
        #expect(page.moves == ["visible", "capture", "hidden"])
    }

    @Test func aRefusedFreezeLeavesThePageHiddenAndNeverThawsIt() throws {
        let slot = makeSlot()
        let parking = FakeParking()
        let page = FakePage("a", freezes: false)
        park(page, in: slot, parking: parking)
        #expect(slot.phase == .parked)
        #expect(!slot.isFrozen, "the engine refused: the slot does not report it frozen")
        // A refit shows it again with no thaw.
        slot.refit(to: Self.bigger)
        rig.fire()
        #expect(page.count("thaw") == 0)
        page.paint()
        page.cover()
        #expect(!slot.isFrozen)
        // Nor does a claim thaw it.
        page.calls = []
        let container = NSView(frame: NSRect(origin: .zero, size: Self.bigger))
        let claim = try #require(slot.claim(Self.newTab, into: container, frame: container.bounds))
        page.claimed = true
        #expect(claim.covered)
        #expect(page.moves == ["visible"])
    }

    // MARK: Refit

    @Test func refitWaitsForQuietThenThawsShowsAndParksAgain() {
        let slot = makeSlot()
        let parking = FakeParking()
        let page = FakePage("a")
        park(page, in: slot, parking: parking)
        page.calls = []
        slot.refit(to: Self.bigger)
        // Nothing in the refit's turn: the size is only recorded.
        #expect(slot.phase == .parked)
        #expect(slot.targetSize == Self.bigger)
        #expect(parking.holds == [Self.size])
        #expect(page.moves.isEmpty)
        #expect(rig.queue.count == 1, "one quiet deadline")
        rig.fire()
        #expect(rig.now >= PagePreloadSlot.refitQuiet)
        #expect(slot.phase == .refitting)
        #expect(parking.holds.last == Self.bigger)
        #expect(page.moves == ["thaw", "visible"])
        page.paint()
        page.cover()
        #expect(slot.phase == .parked)
        #expect(page.moves == ["thaw", "visible", "capture", "hidden", "freeze"])
        slot.refit(to: Self.bigger)
        #expect(rig.queue.count == 0, "the same size arms nothing")
        #expect(page.moves.count == 5, "the same size changes nothing")
    }

    @Test func aBurstOfRefitsCostsOneThawOneCaptureOneFreeze() {
        let slot = makeSlot()
        let parking = FakeParking()
        let page = FakePage("a")
        park(page, in: slot, parking: parking)
        page.calls = []
        for step in 1...10 {
            rig.advance(to: .milliseconds(16 * step))
            slot.refit(to: NSSize(width: 800 + 20 * step, height: 600 + 10 * step))
            // The engine paints between the steps of a drag.
            page.paint()
            page.cover()
            #expect(rig.queue.count == 1, "step \(step): one deadline, pushed back")
        }
        #expect(page.moves.isEmpty, "no work while the size changes")
        rig.fire()
        page.paint()
        page.cover()
        #expect(slot.phase == .parked)
        #expect(page.count("thaw") == 1)
        #expect(page.count("capture") == 1)
        #expect(page.count("freeze") == 1)
        #expect(parking.holds == [Self.size, NSSize(width: 1_000, height: 700)])
    }

    @Test func aRefitBackToTheLaidOutSizeCancelsThePendingOne() {
        let slot = makeSlot()
        let page = FakePage("a")
        park(page, in: slot, parking: FakeParking())
        page.calls = []
        slot.refit(to: Self.bigger)
        slot.refit(to: Self.size)
        #expect(rig.queue.count == 0)
        rig.fire()
        #expect(page.moves.isEmpty)
        #expect(slot.phase == .parked)
    }

    @Test func refitWhileLoadingParksAtTheOldSizeThenRefitsOnce() {
        let slot = makeSlot()
        let parking = FakeParking()
        let page = FakePage("a")
        let smaller = NSSize(width: 500, height: 400)
        slot.preload(Self.newTab, size: Self.size, in: parking) { _ in page }
        slot.refit(to: smaller)
        #expect(slot.phase == .loading)
        page.paint()
        page.cover()
        #expect(slot.phase == .parked)
        rig.fire()
        #expect(slot.phase == .refitting)
        page.paint()
        page.cover()
        #expect(slot.phase == .parked)
        #expect(parking.holds == [Self.size, smaller])
        #expect(page.moves == ["visible", "capture", "hidden", "freeze", "thaw", "visible", "capture", "hidden", "freeze"])
    }

    @Test func aSettleDuringCaptureIgnoresTheOldCover() {
        let slot = makeSlot()
        let parking = FakeParking()
        let page = FakePage("a")
        slot.preload(Self.newTab, size: Self.size, in: parking) { _ in page }
        page.paint()
        #expect(slot.phase == .capturing)
        slot.refit(to: Self.bigger)
        rig.fire()
        #expect(slot.phase == .refitting)
        page.cover() // the cover of the old size
        #expect(slot.phase == .refitting)
        page.paint()
        page.cover()
        #expect(slot.phase == .parked)
        #expect(page.moves == ["visible", "capture", "capture", "hidden", "freeze"])
    }

    @Test func samePreloadInAnotherParkingMovesWithoutReload() {
        let slot = makeSlot()
        let first = FakeParking(), second = FakeParking()
        let page = FakePage("a")
        park(page, in: slot, parking: first)
        var made = 0
        #expect(slot.preload(Self.newTab, size: Self.size, in: second) { _ in made += 1; return FakePage("b") })
        #expect(made == 0)
        #expect(page.preloadView.superview === second.view)
        #expect(slot.phase == .parked)
        #expect(!page.closed)
    }

    @Test func anotherKeyClosesTheHeldPageFirst() {
        let slot = makeSlot()
        let parking = FakeParking()
        let a = FakePage("a"), b = FakePage("b")
        park(a, in: slot, parking: parking)
        slot.preload(Self.settings, size: Self.size, in: parking) { _ in
            #expect(a.closed, "the old page closes before the new one is made")
            return b
        }
        #expect(a.closed)
        #expect(a.preloadView.superview == nil)
        #expect(slot.key == Self.settings)
        #expect(slot.count == 1)
    }

    // MARK: Claim

    @Test func claimShowsTheCoverOnTopThawsThenShows() throws {
        let slot = makeSlot()
        let parking = FakeParking()
        let page = FakePage("a")
        park(page, in: slot, parking: parking)
        page.calls = []
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        let claim = try #require(slot.claim(Self.newTab, into: container, frame: container.bounds))
        page.claimed = true
        #expect(claim.page === page)
        #expect(claim.covered)
        #expect(!claim.refit)
        #expect(slot.count == 0)
        #expect(page.preloadView.superview === container)
        #expect(page.preloadView.frame == container.bounds)
        #expect(page.moves == ["thaw", "visible"], "thaw before visible")
        let cover = try #require(page.preloadView.subviews.last as? PagePreloadCoverView)
        #expect(cover.frame == page.preloadView.bounds)
        #expect(cover.hitTest(NSPoint(x: 10, y: 10)) == nil)
        // The cover goes at the page's first live frame, and its limit with it.
        page.paint()
        #expect(cover.superview == nil)
        #expect(cover.limit == nil)
        #expect(rig.queue.count == 0)
        #expect(page.lateCalls.isEmpty)
    }

    @Test func aClaimAtAnotherSizeShowsNoStretchedCover() throws {
        let slot = makeSlot()
        let page = FakePage("a")
        park(page, in: slot, parking: FakeParking())
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let claim = try #require(slot.claim(Self.newTab, into: container, frame: container.bounds))
        page.claimed = true
        #expect(claim.refit)
        #expect(!claim.covered, "a cover of 800x600 would show stretched in 640x480")
        #expect(!page.preloadView.subviews.contains { $0 is PagePreloadCoverView })
        #expect(page.preloadView.frame == container.bounds)
        #expect(slot.lastClaim?.covered == false)
    }

    /// An opener that does not know the size the page will show at (Cmd-N's new workspace) takes
    /// it without a cover, even at the parked size: that cover could show stretched in the pane.
    @Test func aClaimWithoutCoverShowsNoneAtTheParkedSize() throws {
        let slot = makeSlot()
        let page = FakePage("a")
        park(page, in: slot, parking: FakeParking())
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        let claim = try #require(slot.claim(Self.newTab, into: container, frame: container.bounds, cover: false))
        page.claimed = true
        #expect(!claim.covered)
        #expect(!claim.refit)
        #expect(!page.preloadView.subviews.contains { $0 is PagePreloadCoverView })
        #expect(page.moves == ["thaw", "visible"], "thaw before visible")
        #expect(rig.queue.count == 0, "a cover limit with no cover")
    }

    /// The default preload hears when another page leaves the slot, by a claim or a drop.
    @Test func aClaimOrADropReportsTheEmptiedSlot() throws {
        @MainActor final class Tally {
            var count = 0
            var keys: [PagePreloadSlot.Key] = []
        }
        let slot = makeSlot()
        let emptied = Tally()
        slot.observeEmptied { key in
            emptied.count += 1
            emptied.keys.append(key)
        }
        let page = FakePage("a")
        park(page, in: slot, parking: FakeParking())
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        _ = try #require(slot.claim(Self.newTab, into: container, frame: container.bounds))
        page.claimed = true
        #expect(emptied.count == 1)
        let other = FakePage("b")
        park(other, in: slot, key: Self.settings, parking: FakeParking())
        #expect(emptied.count == 1, "the slot was empty already when the preload began")
        slot.drop()
        #expect(emptied.count == 2)
        #expect(other.closed)
        slot.drop()
        #expect(emptied.count == 2, "a drop of an empty slot reported it emptied")
        #expect(emptied.keys == [Self.newTab, Self.settings])
    }

    @Test func aClaimBeforeTheQuietRefitUsesTheLaidOutSize() throws {
        let slot = makeSlot()
        let page = FakePage("a")
        park(page, in: slot, parking: FakeParking())
        slot.refit(to: Self.bigger)
        let container = NSView(frame: NSRect(origin: .zero, size: Self.bigger))
        let claim = try #require(slot.claim(Self.newTab, into: container, frame: container.bounds))
        page.claimed = true
        #expect(claim.refit)
        #expect(!claim.covered)
        #expect(rig.queue.count == 0, "the claim cancels the pending refit")
        rig.fire()
        #expect(page.lateCalls.isEmpty)
    }

    @Test func aCoverWithNoLiveFrameGoesAtItsLimit() throws {
        let slot = makeSlot()
        let page = FakePage("a")
        park(page, in: slot, parking: FakeParking())
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        _ = try #require(slot.claim(Self.newTab, into: container, frame: container.bounds))
        page.claimed = true
        let cover = try #require(page.preloadView.subviews.last as? PagePreloadCoverView)
        #expect(rig.queue.count == 1, "the cover's limit")
        // The renderer died while parked: no frame comes.
        rig.fire()
        #expect(rig.now >= PagePreloadSlot.coverLimit)
        #expect(cover.superview == nil)
        // A late frame finds nothing to take off.
        page.paint()
        #expect(page.lateCalls.isEmpty)
    }

    /// Claim and cover removal run inside an implicit-animation group, where a layer-backed view's
    /// frame change and a layer's contents and order changes would animate, and add no animation.
    @Test func claimAndCoverRemovalAddNoAnimationInAnImplicitAnimationGroup() throws {
        let slot = makeSlot()
        let page = FakePage("a")
        page.preloadView.wantsLayer = true
        park(page, in: slot, parking: FakeParking())
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 900))
        container.wantsLayer = true
        // Another origin than the parking's, so a position change would animate.
        let frame = NSRect(origin: NSPoint(x: 40, y: 30), size: Self.size)
        var claim: PagePreloadSlot.Claim?
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1
            context.allowsImplicitAnimation = true
            claim = slot.claim(Self.newTab, into: container, frame: frame)
        }
        #expect(claim?.covered == true)
        let cover = try #require(page.preloadView.subviews.last as? PagePreloadCoverView)
        let coverLayer = try #require(cover.layer)
        let pageLayer = try #require(page.preloadView.layer)
        #expect(coverLayer.contents != nil)
        #expect((coverLayer.animationKeys() ?? []).isEmpty)
        #expect((pageLayer.animationKeys() ?? []).isEmpty)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1
            context.allowsImplicitAnimation = true
            page.paint()
        }
        #expect(cover.superview == nil)
        #expect((coverLayer.animationKeys() ?? []).isEmpty)
        #expect((pageLayer.animationKeys() ?? []).isEmpty)
    }

    @Test func claimBeforeParkHandsTheLivePageWithoutCover() throws {
        let slot = makeSlot()
        let page = FakePage("a")
        slot.preload(Self.newTab, size: Self.size, in: FakeParking()) { _ in page }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let claim = try #require(slot.claim(Self.newTab, into: container, frame: container.bounds))
        page.claimed = true
        #expect(!claim.covered)
        #expect(claim.refit)
        #expect(page.preloadView.subviews.isEmpty)
        // Its load's paint comes later: the slot no longer parks it.
        page.paint()
        page.cover()
        #expect(page.lateCalls.isEmpty)
        #expect(!page.moves.contains("freeze"))
    }

    @Test func claimOfAnotherKeyLeavesTheSlot() {
        let slot = makeSlot()
        let page = FakePage("a")
        park(page, in: slot, parking: FakeParking())
        #expect(slot.claim(Self.settings, into: NSView(), frame: .zero) == nil)
        #expect(slot.count == 1)
        #expect(slot.phase == .parked)
    }

    /// The claim's main-thread time with fakes, as PagePreloadClaimReadyBenchmark (PageHostPoolClaimReadyBenchmark before) measures the
    /// claim: <= 4 ms at p99 (D4: main-thread work in the key's turn).
    @Test func claimTakesAtMostFourMillisecondsAtP99() throws {
        let slot = makeSlot()
        let parking = FakeParking()
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        var samples: [Double] = []
        for index in 0..<200 {
            let page = FakePage("\(index)")
            park(page, in: slot, parking: parking)
            let start = ContinuousClock.now
            let claim = try #require(slot.claim(Self.newTab, into: container, frame: container.bounds))
            let (seconds, attoseconds) = (ContinuousClock.now - start).components
            samples.append(Double(seconds) * 1_000 + Double(attoseconds) / 1e15)
            #expect(claim.milliseconds <= samples[samples.count - 1])
            page.paint()
            page.preloadView.removeFromSuperview()
        }
        samples.sort()
        let p99 = samples[Int(Double(samples.count - 1) * 0.99)]
        #expect(p99 <= 4, "claim p99 \(p99) ms")
        #expect(slot.lastClaim?.covered == true)
    }

    // MARK: Pressure

    @Test func pressureDropsAndRefusesUntilNormal() {
        let slot = makeSlot()
        let parking = FakeParking()
        let page = FakePage("a")
        park(page, in: slot, parking: parking)
        slot.refit(to: Self.bigger)
        slot.memoryPressureDidChange(.warning)
        #expect(slot.count == 0)
        #expect(page.closed)
        #expect(page.preloadView.superview == nil)
        #expect(rig.queue.count == 0, "the drop cancels the pending refit")
        var made = 0
        #expect(!slot.preload(Self.newTab, size: Self.size, in: parking) { _ in made += 1; return FakePage("b") })
        #expect(made == 0)
        slot.memoryPressureDidChange(.normal)
        #expect(slot.preload(Self.newTab, size: Self.size, in: parking) { _ in made += 1; return FakePage("b") })
        #expect(made == 1)
    }

    // MARK: Trace

    @Test func movesGoOnTheWebUIPreloadTrack() throws {
        var moves: [(PagePreloadSlot.Move, UInt64)] = []
        let slot = makeSlot { moves.append(($0, $1)) }
        let parking = FakeParking()
        let a = FakePage("a"), b = FakePage("b")
        park(a, in: slot, parking: parking)
        _ = try #require(slot.claim(Self.newTab, into: NSView(), frame: .zero))
        park(b, in: slot, parking: parking)
        slot.drop()
        #expect(moves.map(\.0) == [.park, .claim, .park, .drop])
        #expect(moves.map(\.1) == [a.preloadTraceID, a.preloadTraceID, b.preloadTraceID, b.preloadTraceID])
    }
}
