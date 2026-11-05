import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Observation
import Testing

/// FRAME OWNER REFACTOR S2 (timing): a divider, column-edge or row-edge drag lays
/// the layout out once per display frame, in the window's frame tick, at the newest pointer (Chrome aligns input to
/// the begin-frame: one input batch per frame). Each drag event wrote the model in its own turn and the layout synced
/// it in the next turn (the observation hop); a row edge reconciled in the event's turn. In a real HID drag (film
/// pp-drag-browser, cmux22 120 Hz: 110 drag events in 1.2 s beside two Chromium pages) the geometry committed from
/// mouse events between the frame ticks, and the window's display link ticked 45 times in 1205 ms. Now an event only
/// keeps the pointer and its keys, and the frame tick applies the newest one before the springs step: one model write,
/// one layout pass and at most one overlay sync per frame, however many events came in it.
///
/// `LayoutWorkProbe` wires a shell window as the app does; the test is the clock (`advanceFrame` is one display
/// frame), and every event comes in its own turn, as AppKit delivers them.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct DividerDragFrameTickTests {
    enum Edge: String, CaseIterable, Sendable {
        case split, columnEdge, rowEdge

        var handle: DividerHandleView.Kind {
            switch self {
            case .split: .split("x")
            case .columnEdge: .columnEdge("c0")
            case .rowEdge: .rowEdge("c0", "r1")
            }
        }

        var layout: ScreenLayout {
            switch self {
            case .split, .columnEdge:
                .columns([LayoutColumn(id: "c0", width: 0.5, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))),
                          LayoutColumn(id: "c1", width: 0.5, root: .leaf("p3"))])
            case .rowEdge:
                .columns([LayoutColumn(id: "c0", width: 0.6, root: .leaf("p1"), rows: [LayoutRow(id: "r1", height: 400, root: .leaf("p1")),
                                                                                       LayoutRow(id: "r2", height: 400, root: .leaf("p2"))])])
            }
        }

        /// One drag event's step: along the divider's axis.
        var step: CGVector { self == .rowEdge ? CGVector(dx: 0, dy: -12) : CGVector(dx: 12, dy: 0) }
    }

    /// What the layout did: model syncs that changed the screen (reconciles), layout passes (presentations) and
    /// overlay syncs (each one asks the window's Chromium pages to follow).
    struct Work: Equatable, CustomStringConvertible {
        var reconciles = 0, presentations = 0, overlaySyncs = 0

        static func - (a: Work, b: Work) -> Work {
            Work(reconciles: a.reconciles - b.reconciles, presentations: a.presentations - b.presentations,
                 overlaySyncs: a.overlaySyncs - b.overlaySyncs)
        }

        var description: String { "reconciles=\(reconciles) presentations=\(presentations) overlay_syncs=\(overlaySyncs)" }
    }

    static func work(_ probe: LayoutWorkProbe) -> Work {
        Work(reconciles: probe.screen.reconcilePasses, presentations: probe.screen.presentationPasses, overlaySyncs: probe.root.overlaySyncs)
    }

    /// Counts the turns in which the model's screens changed: the writes a layout syncs.
    final class ModelWrites {
        private(set) var count = 0
        private let model: LayoutModel

        init(_ model: LayoutModel) {
            self.model = model
            watch()
        }

        private func watch() {
            withObservationTracking { _ = model.screens } onChange: { [weak self] in
                Task { @MainActor in
                    self?.count += 1
                    self?.watch()
                }
            }
        }
    }

    /// The turns after an event, as AppKit's run loop gives them: the model's observation lands in them.
    static func turns() async {
        for _ in 0..<6 { await Task.yield() }
    }

    /// A probe of `layout` (`rows`: with row heights the daemon serves).
    static func probe(_ layout: ScreenLayout, rows: Bool = false) -> LayoutWorkProbe {
        let probe = LayoutWorkProbe(layout, focused: "p1")
        if rows {
            // Row heights are resizable only where the daemon serves rows-v1.
            probe.model.acceptsRowOps = true
            probe.root.syncWithModel()
            probe.settle()
        }
        return probe
    }

    static let twoPanes = ScreenLayout.columns([LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5,
                                                                                                    a: .leaf("p1"), b: .leaf("p2")))])

    /// The window x of `kind`'s handle center.
    static func handleX(_ probe: LayoutWorkProbe, _ kind: DividerHandleView.Kind) throws -> CGFloat {
        let handle = try #require(probe.screen.dividerViews[kind])
        return probe.screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil).x
    }

    @Test(arguments: Edge.allCases)
    func dragEventsInOneFrameLayTheLayoutOutOnceAtTheFrameTick(_ edge: Edge) async throws {
        let probe = Self.probe(edge.layout, rows: edge == .rowEdge)
        defer { probe.close() }
        let screen = probe.screen
        let handle = try #require(screen.dividerViews[edge.handle], "no \(edge) handle in \(screen.dividerViews.keys)")
        let start = screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil)
        handle.mouseDown(with: probe.event(.leftMouseDown, start))
        await Self.turns()

        let writes = ModelWrites(probe.model)
        let before = Self.work(probe)
        // Five drag events inside one display frame, each in its own turn.
        var point = start
        for _ in 1...5 {
            point = CGPoint(x: point.x + edge.step.dx, y: point.y + edge.step.dy)
            handle.mouseDragged(with: probe.event(.leftMouseDragged, point))
            await Self.turns()
        }
        let between = Self.work(probe) - before
        // The frame's tick.
        _ = probe.root.advanceFrame(1.0 / 120)
        await Self.turns()
        let frame = Self.work(probe) - before
        let atTick = frame - between

        #expect(between.reconciles == 0 && between.presentations == 0,
                "\(edge): 5 drag events laid the layout out between frame ticks (\(between))")
        #expect(atTick.reconciles == 1 && atTick.presentations == 1,
                "\(edge): the frame tick laid the layout out \(atTick.presentations) times for 5 drag events (\(atTick)), not once")
        #expect(frame.overlaySyncs <= 1, "\(edge): \(frame.overlaySyncs) overlay syncs (page updates) in one frame of drag events")
        // A row edge writes the model once, at its release (rows.md Z1); a divider and a column edge once per frame.
        if edge != .rowEdge {
            #expect(writes.count == 1, "\(edge): \(writes.count) model writes in one frame of drag events")
        }
        if edge == .split {
            // The frame shows the newest pointer: the divider sits 5 steps from where it was grabbed.
            let shown = screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil)
            #expect(abs(shown.x - (start.x + 5 * edge.step.dx)) <= 1, "the divider shows at \(shown.x), the pointer is at \(point.x)")
        }

        handle.mouseUp(with: probe.event(.leftMouseUp, point))
        await Self.turns()
        probe.settle()
    }

    /// A release while an event waits for the frame: the release lands at its own point in its own turn, and no later
    /// frame writes the waiting pointer again.
    @Test func aReleaseWhileAnEventWaitsLandsAtItsOwnPointOnce() async throws {
        let probe = Self.probe(Self.twoPanes)
        defer { probe.close() }
        let handle = try #require(probe.screen.dividerViews[.split("x")])
        let start = try Self.handleX(probe, .split("x"))
        let y = probe.screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil).y
        handle.mouseDown(with: probe.event(.leftMouseDown, CGPoint(x: start, y: y)))
        handle.mouseDragged(with: probe.event(.leftMouseDragged, CGPoint(x: start + 40, y: y)))
        // Released 80 pt right before any frame wrote the waiting 40 pt sample.
        handle.mouseUp(with: probe.event(.leftMouseUp, CGPoint(x: start + 80, y: y)))
        await Self.turns()
        probe.settle()
        let landed = try Self.handleX(probe, .split("x"))
        #expect(abs(landed - (start + 80)) <= 1, "the release landed at \(landed), not at its point \(start + 80)")
        for _ in 0..<3 { _ = probe.root.advanceFrame(1.0 / 120) }
        #expect(try Self.handleX(probe, .split("x")) == landed, "a frame after the release wrote the drag again")
        #expect(probe.screen.activeDrag == nil)
    }

    /// Control moves the divider at a quarter of the pointer's speed for the events it is held at, also when several
    /// events come in one frame: its trail follows each event with the keys held at it, not only the one the frame
    /// writes. Two events with no key (40 pt) and two with Control (40 pt at a quarter) put the divider 50 pt along.
    @Test func controlKeepsAQuarterOfThePointerOverEventsInOneFrame() async throws {
        let probe = Self.probe(Self.twoPanes)
        defer { probe.close() }
        let handle = try #require(probe.screen.dividerViews[.split("x")])
        let start = try Self.handleX(probe, .split("x"))
        let y = probe.screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil).y
        handle.mouseDown(with: probe.event(.leftMouseDown, CGPoint(x: start, y: y)))
        for step in 1...4 {
            let keys: NSEvent.ModifierFlags = step > 2 ? .control : []
            handle.mouseDragged(with: probe.event(.leftMouseDragged, CGPoint(x: start + CGFloat(step) * 20, y: y), keys))
        }
        _ = probe.root.advanceFrame(1.0 / 120)
        let shown = try Self.handleX(probe, .split("x"))
        #expect(abs(shown - (start + 50)) <= 1, "40 pt with no key and 40 pt with Control moved the divider \(shown - start) pt, not 50")
        handle.mouseUp(with: probe.event(.leftMouseUp, CGPoint(x: start + 80, y: y), .control))
        await Self.turns()
        probe.settle()
    }

    /// With Reduce Motion on, a frame tick lands everything at once and still writes the drag's newest pointer.
    @Test func reduceMotionStillLaysTheDragOutAtTheFrameTick() async throws {
        let probe = Self.probe(Self.twoPanes)
        defer { probe.close() }
        probe.root.context.reduceMotionOverride = true
        let handle = try #require(probe.screen.dividerViews[.split("x")])
        let start = try Self.handleX(probe, .split("x"))
        let y = probe.screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil).y
        handle.mouseDown(with: probe.event(.leftMouseDown, CGPoint(x: start, y: y)))
        handle.mouseDragged(with: probe.event(.leftMouseDragged, CGPoint(x: start + 30, y: y)))
        handle.mouseDragged(with: probe.event(.leftMouseDragged, CGPoint(x: start + 60, y: y)))
        #expect(probe.root.advanceFrame(1.0 / 120), "a drag keeps the frame ticks under Reduce Motion")
        let shown = try Self.handleX(probe, .split("x"))
        #expect(abs(shown - (start + 60)) <= 1, "the divider shows at \(shown - start) pt, the pointer is at 60")
        handle.mouseUp(with: probe.event(.leftMouseUp, CGPoint(x: start + 60, y: y)))
        await Self.turns()
        probe.settle()
    }
}
