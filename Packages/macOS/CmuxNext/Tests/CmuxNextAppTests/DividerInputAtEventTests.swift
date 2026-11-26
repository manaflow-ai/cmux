import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// Page-sync lever 2 (artifacts/in-tree-pages/page-sync, `CMUX_NEXT_DIVIDER_INPUT_AT_EVENT=1`): a divider drag's first
/// event of a display frame lays the layout out in its own turn, so the panes (and the Chromium pages in them) take
/// the new size when the pointer moves instead of at the window's next display-link tick, up to a refresh later. The
/// rest of the frame's events wait for the tick as before (DividerDragFrameTickTests): at most two layout passes a
/// frame however many events come. With the knob off nothing changes.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct DividerInputAtEventTests {
    typealias Tick = DividerDragFrameTickTests

    /// The divider's handle center (window x) after each step: a press, `events` drag events of 12 pt in one frame,
    /// then the frame tick. `landsAtEvent` sets the knob for this layout only.
    struct Drag {
        var afterFirstEvent: CGFloat = 0, afterLastEvent: CGFloat = 0, afterTick: CGFloat = 0
        var presentationsBeforeTick = 0, presentationsAtTick = 0
        var start: CGFloat = 0
    }

    static func drag(landsAtEvent: Bool, events: Int) async throws -> Drag {
        let probe = Tick.probe(Tick.twoPanes)
        defer { probe.close() }
        probe.root.context.inputLandsAtEvent = landsAtEvent
        let handle = try #require(probe.screen.dividerViews[.split("x")])
        var out = Drag()
        out.start = try Tick.handleX(probe, .split("x"))
        let y = probe.screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil).y
        handle.mouseDown(with: probe.event(.leftMouseDown, CGPoint(x: out.start, y: y)))
        await Tick.turns()
        _ = probe.root.advanceFrame(1.0 / 120)  // the press's own frame: the next event is the frame's first
        let before = Tick.work(probe)
        for step in 1...events {
            handle.mouseDragged(with: probe.event(.leftMouseDragged, CGPoint(x: out.start + CGFloat(step) * 12, y: y)))
            await Tick.turns()
            if step == 1 { out.afterFirstEvent = try Tick.handleX(probe, .split("x")) }
        }
        out.afterLastEvent = try Tick.handleX(probe, .split("x"))
        out.presentationsBeforeTick = (Tick.work(probe) - before).presentations
        _ = probe.root.advanceFrame(1.0 / 120)
        await Tick.turns()
        out.presentationsAtTick = (Tick.work(probe) - before).presentations - out.presentationsBeforeTick
        out.afterTick = try Tick.handleX(probe, .split("x"))
        handle.mouseUp(with: probe.event(.leftMouseUp, CGPoint(x: out.start + CGFloat(events) * 12, y: y)))
        await Tick.turns()
        probe.settle()
        return out
    }

    @Test func theFirstEventOfAFrameShowsAtOnceWithTheKnob() async throws {
        let d = try await Self.drag(landsAtEvent: true, events: 1)
        #expect(abs(d.afterFirstEvent - (d.start + 12)) <= 1,
                "the first drag event of the frame showed the divider \(d.afterFirstEvent - d.start) pt along, not 12, before the tick")
        #expect(d.presentationsBeforeTick == 1, "\(d.presentationsBeforeTick) layout passes at the event, not 1")
        #expect(abs(d.afterTick - (d.start + 12)) <= 1)
    }

    @Test func theRestOfTheFramesEventsWaitForTheTick() async throws {
        let d = try await Self.drag(landsAtEvent: true, events: 5)
        #expect(abs(d.afterFirstEvent - (d.start + 12)) <= 1, "the frame's first event did not land at once")
        #expect(abs(d.afterLastEvent - (d.start + 12)) <= 1,
                "a later event of the same frame laid out before the tick (divider \(d.afterLastEvent - d.start) pt along)")
        #expect(d.presentationsBeforeTick == 1, "\(d.presentationsBeforeTick) layout passes between ticks for 5 events, not 1")
        #expect(d.presentationsAtTick == 1, "the tick laid out \(d.presentationsAtTick) times, not once")
        #expect(abs(d.afterTick - (d.start + 60)) <= 1, "the tick showed \(d.afterTick - d.start) pt, not the newest pointer (60)")
    }

    @Test func withoutTheKnobEveryEventWaitsForTheTick() async throws {
        let d = try await Self.drag(landsAtEvent: false, events: 1)
        #expect(abs(d.afterFirstEvent - d.start) <= 1, "with the knob off the event moved the divider before the tick")
        #expect(d.presentationsBeforeTick == 0)
        #expect(abs(d.afterTick - (d.start + 12)) <= 1)
    }
}
