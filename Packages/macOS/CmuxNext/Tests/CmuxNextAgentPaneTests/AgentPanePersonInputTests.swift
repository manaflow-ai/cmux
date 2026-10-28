import AppKit
import CmuxNextPagesTestSupport
@testable import CmuxNextAgentPane
import CmuxNextInput
import CmuxNextWakeups
import Testing

/// A native choice grants the agent pane a gesture only from the event it answers: a script or
/// socket run right after the person's key or click is not the person, though AppKit still keeps that event as its
/// current one. A file drop, which no dispatch carries, is the person's when the person's hand ended the drag.
@MainActor @Suite(.serialized)
struct AgentPanePersonInputTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The event a fake dispatch holds and AppKit's current event: a class, so the `@MainActor` sources share them.
    final class Dispatch {
        var event: NSEvent?
        var current: NSEvent?
    }

    /// A tap fed as `CmuxApplication.sendEvent` feeds it, from `dispatch`.
    private static func tap(_ dispatch: Dispatch) -> InputEventTap {
        let tap = InputEventTap()
        (tap.dispatchedEvent, tap.currentEvent) = ({ dispatch.event }, { dispatch.current })
        return tap
    }

    /// An event from the HID system (source pid 0), as the person's hand makes it.
    private static func hid(_ type: CGEventType, at timestamp: TimeInterval) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left))
        cgEvent.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        cgEvent.timestamp = CGEventTimestamp(timestamp * 1_000_000_000)
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    @Test func aRunAfterThePersonsKeyIsNotThePerson() throws {
        _ = NSApplication.shared
        let dispatch = Dispatch()
        let tap = Self.tap(dispatch)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                context: nil, characters: "v", charactersIgnoringModifiers: "v",
                                                isARepeat: false, keyCode: 9))
        tap.sendEventBegan(key)
        (dispatch.event, dispatch.current) = (key, key)
        #expect(AgentPanePersonInput.isPerson(answering: tap) == AgentPanePersonInput.isPerson(key),
                "the key being dispatched is the event its paste answers")
        dispatch.event = nil
        tap.sendEventEnded()
        #expect(!AgentPanePersonInput.isPerson(answering: tap), "a run after the dispatch took the person's key as its own")
    }

    /// The person clicks a button and leaves the pointer still; an agent then forks through the socket.
    @Test func aSocketRunAfterTheButtonsTrackingLoopIsNotThePerson() throws {
        _ = NSApplication.shared
        let dispatch = Dispatch()
        let tap = Self.tap(dispatch)
        let down = try Self.hid(.leftMouseDown, at: 100)
        let up = try Self.hid(.leftMouseUp, at: 100.1)
        try #require(AgentPanePersonInput.isPerson(up), "the test's mouse-up is not the person's; the check below would prove nothing")
        tap.sendEventBegan(down)
        (dispatch.event, dispatch.current) = (down, down)
        tap.deliverObserve(down)
        dispatch.current = up // the button's trackMouse dequeued the mouse-up and never dispatched it
        #expect(AgentPanePersonInput.isPerson(answering: tap), "the button's own action is the person's click")
        dispatch.event = nil
        tap.sendEventEnded()

        let gestures = AgentPaneUserGestures()
        AgentPanePersonInput.record(gestures, input: tap)
        #expect(!gestures.isAvailable, "the socket run recorded the stale mouse-up as the person's gesture")
    }

    @Test func theHandThatEndedTheDragDecides() {
        #expect(AgentPanePersonInput.DragEnd(sinceHIDRelease: 0.01, sinceSessionDrag: 0.05).isPersons)
        #expect(!AgentPanePersonInput.DragEnd(sinceHIDRelease: 30, sinceSessionDrag: 0.05).isPersons,
                "a posted drag moved after the person's last release")
        #expect(!AgentPanePersonInput.DragEnd(sinceHIDRelease: .infinity, sinceSessionDrag: .infinity).isPersons)
    }

    /// A drop runs outside any dispatch, and AppKit's current event is the last one the tap recorded: the drag's
    /// end, not an event, decides. The person's drop stashes its paths and records a gesture; a posted one neither.
    @Test func aDropOutsideAnyDispatchIsThePersonsWhenTheirHandEndedTheDrag() throws {
        let file = try #require(AgentPageTestRoot.page)
        let router = AgentPaneGestureRouter.testing()
        let last = try Self.hid(.leftMouseUp, at: 50)
        router.input.sendEventBegan(last)
        router.input.deliverObserve(last)
        router.input.currentEvent = { last }
        router.input.sendEventEnded()
        let view = try #require(AgentPaneView(mainThread: .standalone(), model: AgentPaneModel(host: NoHost()), work: BackgroundWork(label: "test.agent-pane"),
                                              source: .bundled(file), webUI: .agentPaneTestHost(), gestures: router))
        defer { view.close() }
        let dropped = try #require(view.page.onFilesDropped, "the pane takes no file drop")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dropped-\(UUID().uuidString).txt")
        let gestures = view.model.transport.gestures

        view.dragEnd = { AgentPanePersonInput.DragEnd(sinceHIDRelease: 30, sinceSessionDrag: 0.05) }
        dropped([url])
        #expect(view.model.droppedPaths.take(.drop, names: [url.lastPathComponent]) == nil, "a posted drop stashed its paths")
        #expect(!gestures.isAvailable, "a posted drop recorded a gesture")

        view.dragEnd = { AgentPanePersonInput.DragEnd(sinceHIDRelease: 0.01, sinceSessionDrag: 0.05) }
        dropped([url])
        #expect(view.model.droppedPaths.take(.drop, names: [url.lastPathComponent]) == [url], "the person's drop was ignored")
        #expect(gestures.isAvailable, "the person's drop recorded no gesture")
    }
}
