import AppKit
import CmuxNextCompat
@testable import CmuxNextPages
import Foundation
import Testing

/// The real window parking of ``PagePreloadSlot`` and the slot's one-held-page property under random
/// sequences of preloads, refits, claims, drops, pressure, deadlines and engine callbacks.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PagePreloadSlotSequenceTests {
    typealias FakePage = PagePreloadSlotTests.FakePage
    typealias FakeParking = PagePreloadSlotTests.FakeParking

    static let newTab = PagePreloadSlotTests.newTab
    static let settings = PagePreloadSlotTests.settings
    static let size = PagePreloadSlotTests.size
    static let bigger = PagePreloadSlotTests.bigger

    /// The slot's deadlines on a wake-up queue only the test fires.
    private let rig = LifecycleDeadlineRig()

    private func makeSlot(_ state: PagePreloadSlot.ParkState = .frozenHidden) -> PagePreloadSlot {
        PagePreloadSlot(parkState: state, deadlines: rig.scheduler) { _, _ in }
    }

    /// Preloads `page` and walks it to parked.
    private func park(_ page: FakePage, in slot: PagePreloadSlot, parking: any PreloadParking) {
        slot.preload(Self.newTab, size: Self.size, in: parking) { _ in page }
        page.paint()
        page.cover()
    }

    // MARK: Parking

    @Test func theWindowParkingIsOffScreenUnhitAndHidden() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = content
        let parking = PagePreloadParkingView(frame: .zero)
        content.addSubview(parking)
        let slot = makeSlot()
        let page = FakePage("a")
        park(page, in: slot, parking: parking)
        #expect(page.preloadView.superview === parking)
        #expect(page.preloadView.frame.size == Self.size)
        #expect(parking.frame.size == Self.size)
        #expect(!content.bounds.intersects(parking.frame), "the parking is outside the content")
        #expect(parking.alphaValue == 0)
        #expect(parking.hitTest(NSPoint(x: parking.frame.midX, y: parking.frame.midY)) == nil)
        #expect(content.hitTest(NSPoint(x: 10, y: 10)) !== page.preloadView)
        #expect(parking.accessibilityChildren()?.isEmpty == true)
        #expect(parking.isAccessibilityHidden())
        slot.refit(to: Self.bigger)
        rig.fire()
        #expect(page.preloadView.frame.size == Self.bigger)
        #expect(parking.frame.size == Self.bigger)
        #expect(!content.bounds.intersects(parking.frame))
    }

    @Test func aParkingHeldBeforeItIsAddedGoesOffScreenWhenAdded() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let parking = PagePreloadParkingView(frame: .zero)
        let page = FakePage("a")
        parking.hold(page.preloadView, at: Self.size)
        #expect(page.preloadView.frame.size == Self.size)
        content.addSubview(parking)
        #expect(parking.frame.size == Self.size)
        #expect(!content.bounds.intersects(parking.frame))
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
            switch random.next() % 10 {
            case 0, 1:
                let page = FakePage("\(step)", freezes: random.next() % 4 != 0)
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
            case 6:
                // The quiet deadline (or a cover's limit) comes.
                rig.fire()
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
                // A thaw only follows a freeze the engine took.
                #expect(page.count("thaw") <= (page.freezes ? page.count("freeze") : 0),
                        "seed \(seed) step \(step): a thaw without a taken freeze")
            }
            if slot.phase == .parked, state == .renderedParked { #expect(!(held.first?.calls.contains("freeze") ?? false)) }
        }
        for page in pages {
            #expect(page.lateCalls.isEmpty, "seed \(seed): \(page.name) got \(page.lateCalls) after it left the slot")
        }
    }
}
