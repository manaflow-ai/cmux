import AppKit
import CmuxNextInputCore
@testable import CmuxNextRemoteBrowser
import CmuxNextRemoteView
import Testing

#if DEBUG
/// A remote tab's page pointer once per frame (feature `pointerFrameRemoteInput`): with
/// the window's FrameInputCoalescer a frame interval's first move goes to the page at
/// once and the rest once at the frame, to the latest point; scrolls in the middle of a gesture sum per
/// phase; buttons, enter, leave, keys and scroll phase edges send what waits first (Chromium's
/// rAF-aligned input and `ShouldFlushQueue`, `third_party/blink/renderer/platform/widget/input/
/// main_thread_event_queue.cc`).
@MainActor @Suite(.serialized) struct RemoteBrowserInputTests {
    enum Call: Equatable {
        /// A single event, as it came.
        case event(NSEvent.EventType)
        /// A frame delivery: its kind, latest x (0 for a scroll), how many events it merged, its summed scroll.
        case frame(PointerCoalescedKind, x: Double, merged: Int, dy: Double, clickCount: Int)
        case key(NSEvent.EventType)
    }

    final class Target: RemoteBrowserEventTarget {
        var calls: [Call] = []
        func handleKeyEquivalent(_ event: NSEvent) -> Bool { false }
        func handleKey(_ event: NSEvent) { calls.append(.key(event.type)) }
        func handlePointer(_ event: NSEvent) { calls.append(.event(event.type)) }
        func handlePointerFrame(_ input: PointerCoalescedInput, clickCount: Int) {
            // A synthesized scroll has no window, so its location is wherever the pointer is: not compared.
            calls.append(.frame(input.kind, x: input.kind == .scroll ? 0 : input.latest.location.x, merged: input.coalescedCount,
                                dy: input.scrollDelta.y, clickCount: clickCount))
        }
        /// The deliveries the page got for moves (single or merged).
        var moves: Int { calls.filter { if case .frame(.move, _, _, _, _) = $0 { true } else { false } }.count }
    }

    final class Harness {
        let view = RemoteBrowserContentView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let target = Target()
        let window: NSWindow
        let rig = PointerFrameTestRig()

        /// `coalesced`: the pointer goes through the window's coalescer (the feature on).
        init(coalesced: Bool = true) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.eventTarget = target
            view.pointerFrames = coalesced ? rig.coalescers : nil
        }

        func mouse(_ type: NSEvent.EventType, x: CGFloat, clickCount: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 300), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
        }

        /// A trackpad scroll of `dy` points in `phase` (or momentum `momentum`).
        func scroll(dy: Int32, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none) -> NSEvent {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: 0, wheel3: 0)!
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
            return NSEvent(cgEvent: cg)!
        }

        /// A mouse-wheel notch of `lines`: no phase, no momentum, line deltas.
        func wheelNotch(lines: Int32 = 1) -> NSEvent {
            NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!)!
        }

        func close() {
            rig.close()
            window.close()
        }
    }

    /// Mouse-wheel notches have no phase and merge like a gesture's middle (Chromium merges wheels of
    /// equal phase, none included): eight in one frame reach the page twice, the second with the sum
    /// of the other seven.
    @Test func eightWheelNotchesInOneFrameReachThePageTwice() {
        let harness = Harness()
        defer { harness.close() }
        let notch = harness.wheelNotch()
        let lines = Double(notch.scrollingDeltaY)
        harness.view.scrollWheel(with: notch)
        for _ in 1...7 { harness.view.scrollWheel(with: harness.wheelNotch()) }
        #expect(harness.target.calls == [.frame(.scroll, x: 0, merged: 1, dy: lines, clickCount: 0)])
        harness.rig.frame()
        var sum = lines
        for _ in 2...7 { sum += lines }
        #expect(harness.target.calls == [.frame(.scroll, x: 0, merged: 1, dy: lines, clickCount: 0),
                                         .frame(.scroll, x: 0, merged: 7, dy: sum, clickCount: 0)])
        #expect(!harness.rig.coalescer.hasPending)
    }

    /// A merged notch carries deltas no newer notch repeats, so the wire must deliver it; merged moves
    /// and mid-gesture scrolls may still be superseded, as the single events are.
    @Test func mergedWheelNotchesMustBeDelivered() throws {
        func scroll(_ dy: Double, _ phase: InputScrollPhase) -> InputEventRecord {
            InputEventRecord(type: .scrollWheel, timestamp: 1, scrollPhase: phase, scrollDelta: InputPoint(x: 0, y: dy))
        }
        var notches = try #require(PointerCoalescedInput(scroll(1, .none)))
        notches.merge(scroll(1, .none))
        #expect(RemoteBrowserInputEncoder.mustDeliver(notches))
        let gesture = try #require(PointerCoalescedInput(scroll(3, .changed)))
        #expect(!RemoteBrowserInputEncoder.mustDeliver(gesture))
        let move = try #require(PointerCoalescedInput(InputEventRecord(type: .mouseMoved, timestamp: 1, location: InputPoint(x: 1, y: 1))))
        #expect(!RemoteBrowserInputEncoder.mustDeliver(move))
    }

    /// Eight moves in one frame: the page gets the first at once and the other seven once at the frame.
    @Test func eightMovesInOneFrameReachThePageTwice() {
        let harness = Harness()
        defer { harness.close() }
        for step in 1...8 {
            harness.view.mouseMoved(with: harness.mouse(.mouseMoved, x: 100 + CGFloat(step) * 10))
        }
        #expect(harness.target.calls == [.frame(.move, x: 110, merged: 1, dy: 0, clickCount: 0)])
        harness.rig.frame()
        #expect(harness.target.calls == [.frame(.move, x: 110, merged: 1, dy: 0, clickCount: 0),
                                         .frame(.move, x: 180, merged: 7, dy: 0, clickCount: 0)])
        harness.rig.frame()
        #expect(harness.target.moves == 2, "an idle frame sends nothing")
    }

    /// Without the coalescer (the feature off) every move goes to the page as it came.
    @Test func withoutTheCoalescerEveryMoveGoesAsItCame() {
        let harness = Harness(coalesced: false)
        defer { harness.close() }
        for step in 1...8 {
            harness.view.mouseMoved(with: harness.mouse(.mouseMoved, x: 100 + CGFloat(step) * 10))
        }
        #expect(harness.target.calls == Array(repeating: .event(.mouseMoved), count: 8))
    }

    /// A press, a release and a leave each send the waiting move first, and the move after them is a
    /// leading edge again: the page sees every event in the order it came, and a drag carries the
    /// press's click count.
    @Test func discreteEventsSendTheWaitingMovesFirst() {
        let harness = Harness()
        defer { harness.close() }
        harness.view.mouseMoved(with: harness.mouse(.mouseMoved, x: 110))
        harness.view.mouseMoved(with: harness.mouse(.mouseMoved, x: 120))
        harness.view.mouseDown(with: harness.mouse(.leftMouseDown, x: 120, clickCount: 2))
        harness.view.mouseDragged(with: harness.mouse(.leftMouseDragged, x: 130))
        harness.view.mouseDragged(with: harness.mouse(.leftMouseDragged, x: 140))
        harness.view.mouseUp(with: harness.mouse(.leftMouseUp, x: 140))
        harness.view.mouseMoved(with: harness.mouse(.mouseMoved, x: 150))
        harness.view.mouseExited(with: NSEvent.enterExitEvent(with: .mouseExited, location: NSPoint(x: 150, y: 300), modifierFlags: [], timestamp: 0,
                                                              windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0,
                                                              trackingNumber: 0, userData: nil)!)
        #expect(harness.target.calls == [
            .frame(.move, x: 110, merged: 1, dy: 0, clickCount: 0),
            .frame(.move, x: 120, merged: 1, dy: 0, clickCount: 0),
            .event(.leftMouseDown),
            .frame(.drag, x: 130, merged: 1, dy: 0, clickCount: 2),
            .frame(.drag, x: 140, merged: 1, dy: 0, clickCount: 2),
            .event(.leftMouseUp),
            .frame(.move, x: 150, merged: 1, dy: 0, clickCount: 0),
            .event(.mouseExited),
        ])
        #expect(!harness.rig.coalescer.hasPending)
    }

    /// Scrolls in the middle of a gesture sum per phase; the gesture's edges go as they came, after
    /// what waits, so the page keeps its began, ended and momentum began for elastic scrolling.
    @Test func midGestureScrollsSumPerPhase() {
        let harness = Harness()
        defer { harness.close() }
        harness.view.scrollWheel(with: harness.scroll(dy: 1, phase: .began))
        for _ in 1...4 { harness.view.scrollWheel(with: harness.scroll(dy: 3, phase: .changed)) }
        harness.view.scrollWheel(with: harness.scroll(dy: 0, phase: .ended))
        harness.rig.frame()
        harness.view.scrollWheel(with: harness.scroll(dy: 5, momentum: .begin))
        for _ in 1...3 { harness.view.scrollWheel(with: harness.scroll(dy: 2, momentum: .continuous)) }
        harness.rig.frame()
        harness.view.scrollWheel(with: harness.scroll(dy: 0, momentum: .end))
        #expect(harness.target.calls == [
            .event(.scrollWheel),
            .frame(.scroll, x: 0, merged: 1, dy: 3, clickCount: 0),
            .frame(.scroll, x: 0, merged: 3, dy: 9, clickCount: 0),
            .event(.scrollWheel),
            .event(.scrollWheel),
            .frame(.scroll, x: 0, merged: 1, dy: 2, clickCount: 0),
            .frame(.scroll, x: 0, merged: 2, dy: 4, clickCount: 0),
            .event(.scrollWheel),
        ])
    }

    /// A merged drag goes to the host as one move at the latest point, with the press's click count.
    @Test func aMergedDragEncodesAsOneMoveAtTheLatestPoint() throws {
        var input = try #require(PointerCoalescedInput(InputEventRecord(type: .leftMouseDragged, timestamp: 1, location: InputPoint(x: 10, y: 10))))
        input.merge(InputEventRecord(type: .leftMouseDragged, timestamp: 2, location: InputPoint(x: 40, y: 10)))
        let json = RemoteBrowserInputEncoder.pointer(input, clickCount: 2, at: CGPoint(x: 40, y: 20))
        let fields = try #require(Self.fields(json))
        #expect(fields["e"] == .string("pointer"))
        #expect(fields["kind"] == .string("move"))
        #expect(fields["x"] == .double(40))
        #expect(fields["buttons"] == .int(1), "the left button is held")
        #expect(fields["click_count"] == .int(2))
    }

    /// A merged scroll goes to the host as one wheel with the summed deltas and its phase; a popup
    /// takes no wheel.
    @Test func aMergedScrollEncodesAsOneWheelWithTheSum() throws {
        func scroll(_ dy: Double, _ phase: InputScrollPhase) -> InputEventRecord {
            InputEventRecord(type: .scrollWheel, timestamp: 1, scrollPhase: phase, scrollDelta: InputPoint(x: 0, y: dy), hasPreciseScrollingDeltas: true)
        }
        var gesture = try #require(PointerCoalescedInput(scroll(3, .changed)))
        gesture.merge(scroll(4, .changed))
        let wheel = try #require(Self.fields(RemoteBrowserInputEncoder.pointer(gesture, clickCount: 0, at: .zero)))
        #expect(wheel["e"] == .string("wheel"))
        #expect(wheel["dy"] == .double(7))
        #expect(wheel["phase"] == .string("changed"))
        #expect(wheel["momentum_phase"] == .string("none"))
        var momentum = try #require(PointerCoalescedInput(scroll(2, .momentum)))
        momentum.merge(scroll(1, .momentum))
        let coast = try #require(Self.fields(RemoteBrowserInputEncoder.pointer(momentum, clickCount: 0, at: .zero)))
        #expect(coast["dy"] == .double(3))
        #expect(coast["phase"] == .string("none"))
        #expect(coast["momentum_phase"] == .string("changed"))
        #expect(RemoteBrowserInputEncoder.pointer(gesture, clickCount: 0, at: .zero, surface: 3) == nil)
    }

    private static func fields(_ json: RemoteRdJSON?) -> [String: RemoteRdJSON]? {
        guard case let .object(fields) = json else { return nil }
        return fields
    }
}
#endif
