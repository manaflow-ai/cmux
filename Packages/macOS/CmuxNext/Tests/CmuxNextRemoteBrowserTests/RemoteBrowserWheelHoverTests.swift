import AppKit
import CoreGraphics
import Testing
@testable import CmuxNextRemoteBrowser
import CmuxNextRemoteView

#if DEBUG
/// Scroll wheel and hover reach the remote page: the page view forwards
/// wheel, enter and exit events, asks AppKit for mouse moves, and the
/// encoder writes rb/1 `wheel` events (remote-tab-protocol.md section 6).
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RemoteBrowserWheelHoverTests {
    @Test func aTrackpadScrollBecomesAPreciseWheelEventWithItsPhases() throws {
        let event = try Self.scroll(dx: 3, dy: -12, phase: 1, momentum: 0)
        let json = try #require(RemoteBrowserInputEncoder.pointer(event, at: CGPoint(x: 30, y: 40)))
        guard case let .object(wheel) = json else { Issue.record("not an object"); return }
        #expect(wheel["e"] == .string("wheel"))
        #expect(wheel["surface"] == .int(0))
        #expect(wheel["x"] == .double(30))
        #expect(wheel["y"] == .double(40))
        #expect(wheel["dx"] == .double(Double(event.scrollingDeltaX)))
        #expect(wheel["dy"] == .double(Double(event.scrollingDeltaY)))
        #expect(wheel["precise"] == .bool(true))
        #expect(wheel["phase"] == .string("began"))
        #expect(wheel["momentum_phase"] == .string("none"))
        #expect(wheel["modifiers"] == .int(0))
    }

    @Test func wheelFieldsMatchTheProtocolVector() {
        // schemas/remote-tab/input-mapping.json "a trackpad wheel keeps both phases".
        let json = RemoteBrowserInputEncoder.wheel(
            dx: 0, dy: -42.5, precise: true, phase: .changed, momentumPhase: .began, modifierFlags: [], at: CGPoint(x: 300, y: 200))
        #expect(json == .object([
            "e": .string("wheel"), "surface": .int(0), "x": .double(300), "y": .double(200), "dx": .double(0), "dy": .double(-42.5),
            "precise": .bool(true), "phase": .string("changed"), "momentum_phase": .string("began"), "modifiers": .int(0),
        ]))
    }

    @Test func aMouseWheelNotchIsALineDelta() {
        let json = RemoteBrowserInputEncoder.wheel(
            dx: 0, dy: 1, precise: false, phase: [], momentumPhase: [], modifierFlags: [.shift], at: .zero)
        guard case let .object(wheel) = json else { Issue.record("not an object"); return }
        #expect(wheel["precise"] == .bool(false))
        #expect(wheel["phase"] == .string("none"))
        #expect(wheel["modifiers"] == .int(1))
    }

    @Test func pointerEventsNameTheirSurface() {
        let json = RemoteBrowserInputEncoder.pointer(
            type: .leftMouseDown, button: 0, clickCount: 1, modifierFlags: [], at: CGPoint(x: 5, y: 6), surface: 7)
        guard case let .object(pointer)? = json else { Issue.record("no pointer"); return }
        #expect(pointer["surface"] == .int(7))
        #expect(pointer["x"] == .double(5))
    }

    @Test func thePageViewForwardsWheelEnterAndExit() throws {
        let view = RemoteBrowserPane(source: MockRemoteStreamSource(width: 64, height: 64)).view
        let target = RecordingTarget()
        view.eventTarget = target
        view.scrollWheel(with: try Self.scroll(dx: 0, dy: -4, phase: 2, momentum: 0))
        view.mouseEntered(with: Self.enterExit(.mouseEntered))
        view.mouseExited(with: Self.enterExit(.mouseExited))
        #expect(target.pointers == [.scrollWheel, .mouseEntered, .mouseExited])
    }

    @Test func thePageViewAsksForMouseMovesWhileThePointerIsOverIt() {
        let view = RemoteBrowserPane(source: MockRemoteStreamSource(width: 64, height: 64)).view
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        view.updateTrackingAreas()
        let hover = view.trackingAreas.filter { $0.owner === view && $0.options.contains(.mouseMoved) }
        #expect(hover.count == 1)
        #expect(hover.first?.options.contains(.mouseEnteredAndExited) == true)
    }

    @Test func enterAndExitEncodeWithoutAClickCount() throws {
        let json = try #require(RemoteBrowserInputEncoder.pointer(Self.enterExit(.mouseEntered), at: CGPoint(x: 1, y: 2)))
        guard case let .object(pointer) = json else { Issue.record("not an object"); return }
        #expect(pointer["kind"] == .string("enter"))
        #expect(pointer["click_count"] == .int(0))
    }

    // MARK: Fixtures

    /// A continuous (trackpad) scroll; `phase` and `momentum` are CGScrollPhase / CGMomentumScrollPhase values.
    static func scroll(dx: Int32, dy: Int32, phase: Int64, momentum: Int64) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        cg.flags = []
        return try #require(NSEvent(cgEvent: cg))
    }

    static func enterExit(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.enterExitEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil)!
    }
}

@MainActor
private final class RecordingTarget: RemoteBrowserEventTarget {
    var pointers: [NSEvent.EventType] = []
    func handleKeyEquivalent(_ event: NSEvent) -> Bool { false }
    func handleKey(_ event: NSEvent) {}
    func handlePointer(_ event: NSEvent) { pointers.append(event.type) }
}
#endif
