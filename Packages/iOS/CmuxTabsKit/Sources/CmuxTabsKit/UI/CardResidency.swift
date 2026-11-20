#if os(iOS)
import Observation
import QuartzCore
import SwiftUI

/// One card's residency: whether its view is in the tree. Each card observes
/// only its own slot, so building or releasing a card re-runs that card,
/// never the grid and the other cards.
@MainActor
@Observable
final class CardSlot {
    var built = false
}

/// Builds grid cards near the screen and releases far ones
/// (`CardResidencyPlan`). Cards on screen are built at once while the grid
/// shows (the zoom lands on real cards, a scroll never shows a blank one);
/// the rest are built one per frame, nearest first, only while the grid
/// rests; a hidden grid builds only its on-screen cards, one per frame.
/// Scrolling never re-runs the grid's body: the offset comes in through
/// `scrolled(to:)` and changes only the slots that flip.
@MainActor
final class CardResidency {
    private var slots: [String: CardSlot] = [:]
    private var ids: [String] = []
    private var layout: OverviewLayout?
    private var offset: CGFloat = 0
    private var visible = false
    private var settled = true
    private let plan = CardResidencyPlan()
    private let clock = FrameClock()
    private var ticking = false
    /// Cards built so far (tests and the rig's log).
    private(set) var builds = 0
    private var building = false { didSet { publishBusy() } }
    /// The offset changed within the last `restFrames` frames: any scroll,
    /// a finger's, a deceleration's or one set from code (which the scroll
    /// phase does not report).
    private var moving = false { didSet { publishBusy() } }
    /// Moving or building ahead.
    private(set) var busy = false
    /// Scrolled by a finger or a deceleration (the scroll phase).
    private var scrolling = false
    /// Whether the grid rests: settled, not scrolling, not moving, nothing
    /// left to build. Sent to `idleSink` on change; never observed by a
    /// view, so a scroll that starts or stops re-runs no body.
    private(set) var idle = false
    /// Receives idle changes (the data source's `overviewIdleChanged`). Set
    /// to a closure that holds the source weakly.
    var idleSink: (Bool) -> Void = { _ in } {
        // A sink installed after the first update hears the current state.
        didSet { if idle { idleSink(true) } }
    }
    private let motionClock = FrameClock()
    private var stillFrames = 0
    /// Frames without an offset change before the grid counts as at rest.
    static let restFrames = 6

    private func publishBusy() {
        let now = building || moving
        guard now != busy else { return }
        busy = now
        publishIdle()
    }

    private func publishIdle() {
        let now = settled && visible && !scrolling && !busy
        guard now != idle else { return }
        idle = now
        idleSink(now)
    }

    func setScrolling(_ scrolling: Bool) {
        self.scrolling = scrolling
        // Stopped: building ahead resumes.
        tick()
        publishIdle()
    }

    func slot(_ id: String) -> CardSlot {
        if let slot = slots[id] { return slot }
        let slot = CardSlot()
        slots[id] = slot
        return slot
    }

    func update(ids: [String], layout: OverviewLayout) {
        self.ids = ids
        self.layout = layout
        let listed = Set(ids)
        for id in slots.keys where !listed.contains(id) { slots[id] = nil }
        reconcile(urgent: visible)
    }

    func scrolled(to offset: CGFloat) {
        guard abs(offset - self.offset) > 0.5 else { return }
        self.offset = offset
        stillFrames = 0
        if !moving {
            moving = true
            motionClock.start { [weak self] _ in
                guard let self else { return false }
                self.stillFrames += 1
                guard self.stillFrames >= Self.restFrames else { return true }
                self.moving = false
                // At rest again: building ahead resumes.
                self.tick()
                return false
            }
        }
        // A card on screen is never shown blank: built in this frame (the
        // grid scrolled to reveal the zooming card, or a fling outran the
        // building ahead).
        reconcile(urgent: visible)
    }

    /// The grid is about to show (or was covered): visible cards are built
    /// now, so the first frame of the zoom shows them; the rest follow.
    func setVisible(_ visible: Bool) {
        self.visible = visible
        reconcile(urgent: visible)
        publishIdle()
    }

    func setSettled(_ settled: Bool) {
        self.settled = settled
        tick()
        publishIdle()
    }

    private func isBuilt(_ index: Int) -> Bool {
        index < ids.count && slots[ids[index]]?.built == true
    }

    private func reconcile(urgent: Bool) {
        guard let layout else { return }
        let step = plan.step(layout: layout, offset: offset, isBuilt: isBuilt)
        for i in step.release where i < ids.count { slots[ids[i]]?.built = false }
        if urgent {
            for i in step.visible where i < ids.count { build(ids[i]) }
        }
        tick()
    }

    private func build(_ id: String) {
        let slot = slot(id)
        guard !slot.built else { return }
        slot.built = true
        builds += 1
    }

    /// One card per frame while there is one to build: the keep band while
    /// the grid is at rest, only the on-screen cards while it is hidden or
    /// zooming (they are ready when it opens; nothing else is built then).
    private func tick() {
        guard !ticking, nextToBuild() != nil else { return }
        ticking = true
        building = true
        clock.start { [weak self] _ in
            guard let self, let id = self.nextToBuild() else {
                self?.ticking = false
                self?.building = false
                return false
            }
            self.build(id)
            return true
        }
    }

    /// The next card to build: ahead of the screen only while the grid rests (shown,
    /// settled, not scrolled by a finger or from code); otherwise only an on-screen one.
    func nextToBuild() -> String? {
        guard let layout else { return nil }
        let step = plan.step(layout: layout, offset: offset, isBuilt: isBuilt)
        let next = visible && settled && !scrolling && !moving ? step.next : step.visible.first
        return next.flatMap { $0 < ids.count ? ids[$0] : nil }
    }
}

/// A grid card, in the tree only while its slot is built (or a gesture or
/// the zoom holds it). The card's view is made in this body, so an unbuilt
/// card costs the grid's body nothing (a built value per card was made for
/// all 80 cards on every zoom frame). An unbuilt card is still in the
/// accessibility tree: a bare element in its slot, named after its tab, that
/// opens it, so swiping through the cards with VoiceOver reaches every tab
/// (scrolling to one builds it).
struct ResidentCard<Content: View>: View {
    let slot: CardSlot
    let held: Bool
    let standIn: CardStandIn
    let content: () -> Content

    init(slot: CardSlot, held: Bool, standIn: CardStandIn, @ViewBuilder content: @escaping () -> Content) {
        self.slot = slot
        self.held = held
        self.standIn = standIn
        self.content = content
    }

    var body: some View {
        if slot.built || held {
            content()
        } else {
            standIn
        }
    }
}

/// An unbuilt card's accessibility element: no pixels, no touches. It offers the
/// built card's actions: Open, and Close for a regular card (a pinned one has none).
struct CardStandIn: View {
    var label: String
    var rect: CGRect
    var open: () -> Void
    var close: (() -> Void)?

    struct Action {
        let name: String
        let run: () -> Void
    }

    var actions: [Action] {
        var actions = [Action(name: "Open", run: open)]
        if let close { actions.append(Action(name: "Close", run: close)) }
        return actions
    }

    var body: some View {
        Color.clear
            .frame(width: rect.width, height: rect.height + OverviewLayout.titleRow)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Text(label))
            .accessibilityAddTraits(.isButton)
            .accessibilityActions {
                ForEach(actions, id: \.name) { action in
                    Button(action.name, action: action.run)
                }
            }
            .accessibilityAction(.default, open)
    }
}
#endif
