import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Observation
import Testing

/// FRAME OWNER REFACTOR S2 (timing): with `motion.frameOwner.timing` on, a divider, column-edge or row-edge drag lays
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

    /// The Debug Settings switch the films flip (`motion.frameOwner.timing`), on while `body` runs. It is set by its
    /// key, as the films' override file sets it.
    static func withTiming(_ body: () async throws -> Void) async throws {
        let key = "motion.frameOwner.timing"
        TunableStore.shared.activate(file: nil)
        if TunableStore.shared.descriptor(for: key) == nil {
            let section = TunableSection(id: "frameOwner", title: "Frame Owner", symbol: "timer", order: 52)
            TunableStore.shared.register([TunableDescriptor(key: key, section: section, label: "Frame timing",
                                                            help: "Springs at the time each frame shows; drags in the frame tick.",
                                                            kind: .bool, defaultSource: .fixed(.bool(false)))])
        }
        defer { TunableStore.shared.set(key, nil) }
        try #require(TunableStore.shared.set(key, .bool(true)) == .bool(true), "the switch takes the override")
        try await body()
    }

    @Test(arguments: Edge.allCases)
    func dragEventsInOneFrameLayTheLayoutOutOnceAtTheFrameTick(_ edge: Edge) async throws {
        try await Self.withTiming {
            let probe = LayoutWorkProbe(edge.layout, focused: "p1")
            defer { probe.close() }
            if edge == .rowEdge {
                // Row heights are resizable only where the daemon serves rows-v1.
                probe.model.acceptsRowOps = true
                probe.root.syncWithModel()
                probe.settle()
            }
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
    }
}
