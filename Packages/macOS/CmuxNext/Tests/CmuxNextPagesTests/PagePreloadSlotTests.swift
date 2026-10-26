import AppKit
import CmuxNextCompat
@testable import CmuxNextPages
import CoreGraphics
import Foundation
import QuartzCore
import Testing

/// ``PagePreloadSlot`` holds at most one page, parks it in Chrome's order (visible load, cover,
/// hidden, then frozen), claims it in the open's turn with its cover on top and no implicit action,
/// and drops it on any non-normal pressure through ``WebUIHost``'s subscription (p13-webui-043).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PagePreloadSlotTests {
    /// A page that logs each call and holds its paint and cover callbacks until the test fires them.
    @MainActor final class FakePage: PreloadablePage {
        let name: String
        let preloadView = NSView(frame: .zero)
        var calls: [String] = []
        var paintWaiters: [@MainActor () -> Void] = []
        var coverWaiters: [@MainActor (CGImage?) -> Void] = []
        var closed = false
        var claimed = false
        /// A call the slot made after the page was claimed or closed that only a held page may get.
        var lateCalls: [String] = []

        init(_ name: String) { self.name = name }

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
        func preloadFreeze() { note("freeze") }
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

    private func makeSlot(_ state: PagePreloadSlot.ParkState = .frozenHidden,
                      moves: ((PagePreloadSlot.Move, UInt64) -> Void)? = nil) -> PagePreloadSlot {
        PagePreloadSlot(parkState: state) { move, page in moves?(move, page) }
    }

    /// Preloads `page` and walks it to parked.
    private func park(_ page: FakePage, in slot: PagePreloadSlot, key: PagePreloadSlot.Key = PagePreloadSlotTests.newTab,
                      parking: FakeParking, size: NSSize = PagePreloadSlotTests.size) {
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
        // Loaded visible, cover taken while visible, then hidden before frozen.
        #expect(page.moves == ["visible", "capture", "hidden", "freeze"])
    }

    @Test func renderedParkHidesWithoutFreezing() {
        let slot = makeSlot(.renderedParked)
        let page = FakePage("a")
        park(page, in: slot, parking: FakeParking())
        #expect(slot.phase == .parked)
        #expect(page.moves == ["visible", "capture", "hidden"])
    }

    @Test func refitWhileParkedThawsShowsAndParksAgain() {
        let slot = makeSlot()
        let parking = FakeParking()
        let page = FakePage("a")
        park(page, in: slot, parking: parking)
        page.calls = []
        let bigger = NSSize(width: 1_000, height: 700)
        slot.refit(to: bigger)
        #expect(slot.phase == .refitting)
        #expect(parking.holds.last == bigger)
        #expect(page.moves == ["thaw", "visible"])
        page.paint()
        page.cover()
        #expect(slot.phase == .parked)
        #expect(page.moves == ["thaw", "visible", "capture", "hidden", "freeze"])
        slot.refit(to: bigger)
        #expect(page.moves.count == 5, "the same size changes nothing")
    }

    @Test func refitWhileLoadingIgnoresTheOldPaint() {
        let slot = makeSlot()
        let parking = FakeParking()
        let page = FakePage("a")
        slot.preload(Self.newTab, size: Self.size, in: parking) { _ in page }
        let first = page.paintWaiters.removeFirst()
        slot.refit(to: NSSize(width: 500, height: 400))
        first() // a paint at the old size
        #expect(slot.phase == .loading)
        page.paint()
        page.cover()
        #expect(slot.phase == .parked)
        #expect(page.moves == ["visible", "capture", "hidden", "freeze"])
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
        // The cover goes at the page's first live frame.
        page.paint()
        #expect(cover.superview == nil)
        #expect(page.lateCalls.isEmpty)
    }

    @Test func coverLayerHasNoImplicitActions() throws {
        let slot = makeSlot()
        let page = FakePage("a")
        park(page, in: slot, parking: FakeParking())
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        _ = try #require(slot.claim(Self.newTab, into: container, frame: container.bounds))
        let cover = try #require(page.preloadView.subviews.last as? PagePreloadCoverView)
        let layer = try #require(cover.layer)
        #expect(layer.contents != nil)
        for key in PagePreloadCoverView.quietKeys {
            #expect(layer.action(forKey: key) == nil, "\(key) animates")
        }
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

    /// The claim's main-thread time with fakes, as PageHostPoolClaimReadyBenchmark measured the pool's
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
        slot.memoryPressureDidChange(.warning)
        #expect(slot.count == 0)
        #expect(page.closed)
        #expect(page.preloadView.superview == nil)
        var made = 0
        #expect(!slot.preload(Self.newTab, size: Self.size, in: parking) { _ in made += 1; return FakePage("b") })
        #expect(made == 0)
        slot.memoryPressureDidChange(.normal)
        #expect(slot.preload(Self.newTab, size: Self.size, in: parking) { _ in made += 1; return FakePage("b") })
        #expect(made == 1)
    }

    @Test func hostSubscriptionDropsTheSlot() {
        let source = ManualMemoryPressureSource()
        let host = WebUIHost(chromium: nil, openPanel: nil, memoryPressure: MemoryPressureEvents(source: source))
        let page = FakePage("a")
        park(page, in: host.preload, parking: FakeParking())
        #expect(host.preload.count == 1)
        source.send(.critical)
        #expect(host.preload.count == 0)
        #expect(page.closed)
        #expect(!host.preload.allowsPreload)
        source.send(.normal)
        #expect(host.preload.allowsPreload)
    }

    @Test func hostStartsAtTheCurrentLevel() {
        let source = ManualMemoryPressureSource()
        source.send(.warning)
        let host = WebUIHost(chromium: nil, openPanel: nil, memoryPressure: MemoryPressureEvents(source: source))
        #expect(!host.preload.allowsPreload)
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

    // MARK: Property: one held page at any time

    /// A deterministic generator (SplitMix64), so a failing seed reproduces.
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func atMostOneHeldPageUnderAnySequence(seed: UInt64) {
        var random = Generator(state: seed)
        let state: PagePreloadSlot.ParkState = seed.isMultiple(of: 2) ? .frozenHidden : .renderedParked
        let slot = makeSlot(state)
        let parkings = [FakeParking(), FakeParking()]
        let keys = [Self.newTab, Self.settings]
        let sizes = [Self.size, NSSize(width: 500, height: 400), NSSize(width: 1_200, height: 900)]
        var pages: [FakePage] = []
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        for step in 0..<400 {
            switch random.next() % 9 {
            case 0, 1:
                let page = FakePage("\(step)")
                slot.preload(keys.randomElement(using: &random)!, size: sizes.randomElement(using: &random)!,
                             in: parkings.randomElement(using: &random)!) { _ in
                    pages.append(page)
                    return page
                }
            case 2:
                slot.refit(to: sizes.randomElement(using: &random)!)
            case 3:
                if let claim = slot.claim(keys.randomElement(using: &random)!, into: container, frame: container.bounds) {
                    (claim.page as? FakePage)?.claimed = true
                    claim.page.preloadView.removeFromSuperview()
                }
            case 4:
                slot.drop()
            case 5:
                slot.memoryPressureDidChange([.normal, .normal, .warning, .critical].randomElement(using: &random)!)
            default:
                // An engine callback arrives, for the held page or for one claimed or closed already.
                if let page = pages.randomElement(using: &random) {
                    if random.next() % 2 == 0 { page.paint() } else { page.cover() }
                }
            }
            let held = pages.filter { !$0.closed && !$0.claimed }
            #expect(held.count <= 1, "seed \(seed) step \(step): \(held.count) held pages")
            #expect(held.count == slot.count, "seed \(seed) step \(step): the slot lost a page")
            if slot.pressure != .normal { #expect(slot.count == 0) }
            if let page = held.first {
                #expect(slot.page === page)
                let inParking = parkings.contains { page.preloadView.superview === $0.view }
                #expect(inParking, "seed \(seed) step \(step): the held page left its parking")
            }
            if slot.phase == .parked, state == .renderedParked { #expect(!(held.first?.calls.contains("freeze") ?? false)) }
        }
        for page in pages {
            #expect(page.lateCalls.isEmpty, "seed \(seed): \(page.name) got \(page.lateCalls) after it left the slot")
        }
    }
}
