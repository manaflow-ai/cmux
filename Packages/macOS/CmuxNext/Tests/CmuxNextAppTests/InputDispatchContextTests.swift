import AppKit
import CmuxNextActions
import CmuxNextFocusUI
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// ``InputDispatchContext``: nested dispatches (a synthetic event sent from inside another dispatch, as
/// `DebugNativeInput.sendThroughApp` does) report the innermost event, the outer one again after it, and none
/// after the last one ends.
@MainActor @Suite
struct InputDispatchContextTests {
    private static func event(_ type: NSEvent.EventType, at timestamp: TimeInterval) throws -> NSEvent {
        _ = NSApplication.shared
        if type == .keyDown {
            return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp,
                                                 windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                                 isARepeat: false, keyCode: 0))
        }
        return try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: timestamp, windowNumber: 0,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func nestedDispatchesReportTheInnermostEvent() throws {
        let context = InputDispatchContext()
        let click = try Self.event(.leftMouseDown, at: 1)
        let key = try Self.event(.keyDown, at: 2)
        #expect(context.event == nil)
        context.dispatching(click) {
            #expect(context.event === click)
            #expect(!context.isKeyDown)
            context.dispatching(key) {
                #expect(context.event === key)
                #expect(context.isKeyDown)
            }
            #expect(context.event === click)
        }
        #expect(context.event == nil)
        #expect(!context.isKeyDown)
    }

    /// A switch begun now takes the key or click being dispatched as its input; a mouse move is none, and nothing
    /// is between dispatches (`NSApp.currentEvent` keeps the last event after its dispatch ends).
    @Test func theSwitchInputIsTheDispatchedKeyOrClick() throws {
        let context = InputDispatchContext()
        let click = try Self.event(.leftMouseUp, at: 7)
        let key = try Self.event(.keyDown, at: 8)
        let moved = try Self.event(.mouseMoved, at: 9)
        #expect(context.inputTimestamp == nil)
        context.dispatching(click) {
            #expect(context.inputTimestamp == 7)
            context.dispatching(key) { #expect(context.inputTimestamp == 8) }
            context.dispatching(moved) { #expect(context.inputTimestamp == nil) }
        }
        #expect(context.inputTimestamp == nil, "after the dispatch ends, a later switch has no input")
    }

    /// Outside a dispatch a switch answers the input a page's request carried (`answering`), else the press of the
    /// person's action run in progress (a gated run, a run's task after a daemon reply): the input its `action.*` row
    /// reads. The event being dispatched still wins, and a run no person started answers nothing.
    @Test func outsideADispatchTheSwitchAnswersTheCarriedInput() throws {
        let context = InputDispatchContext()
        let key = try Self.event(.keyDown, at: 8)
        let press = ActionRunScope(origin: .user, allowsViewChange: true, inputTimestamp: 5)
        ActionRunScope.$current.withValue(press) {
            #expect(context.inputTimestamp == 5, "a person's run answers its press")
            context.answering(input: 6) { #expect(context.inputTimestamp == 6, "the page's carried click is innermost") }
            context.dispatching(key) { #expect(context.inputTimestamp == 8, "the event being dispatched wins") }
        }
        ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: true, inputTimestamp: 5)) {
            #expect(context.inputTimestamp == nil, "a CLI run answers no press")
        }
        context.answering(input: nil) { #expect(context.inputTimestamp == nil) }
        #expect(context.answering(input: 6) { context.inputTimestamp } == 6)
        #expect(context.inputTimestamp == nil, "the carried input ends with its work")
    }

    /// A trackpad scroll as `debug.mouse` synthesizes it: `NSEvent(cgEvent:)`, so its `window` is nil.
    private static func scroll(_ phase: CGScrollPhase) throws -> NSEvent {
        _ = NSApplication.shared
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -10, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        return try #require(NSEvent(cgEvent: cg))
    }

    /// A windowless synthesized scroll dispatched with the window it goes to (`debug.mouse`'s path, which never
    /// passes `sendEvent` or the input tap) opens the scroll frame sequence on that window's scheduler; the gesture's
    /// end closes it once the momentum wait passes, and a click ends the next one (p09-observability-113).
    @Test func aWindowlessSynthesizedScrollOpensAndClosesTheScrollSequence() throws {
        let scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: WakeupLedger(), mediaTime: { 1000 }) { _ in DispatchTestLink() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let looked = WindowLog()
        let scrolls = ScrollFrameSequences(schedulerOf: { looked.windows.append($0); return scheduler })
        let context = InputDispatchContext(scrollGestures: { scrolls.note($0, in: $1) })

        let began = try Self.scroll(.began)
        #expect(began.window == nil)
        context.dispatching(began, in: window) {}
        #expect(scheduler.sequences.isOpen(.scroll), "a windowless synthesized scroll opened no scroll sequence")
        #expect(looked.windows.count == 1 && looked.windows.first === window, "the scroll did not count on its dispatch window")
        scheduler.frameDidFire(timestamp: began.timestamp, refreshInterval: 1.0 / 60)
        let ended = try Self.scroll(.ended)
        context.dispatching(ended, in: window) {}
        #expect(scheduler.sequences.isOpen(.scroll), "the gesture's end closed it before the momentum wait")
        scheduler.frameDidFire(timestamp: ended.timestamp + 0.2, refreshInterval: 1.0 / 60)
        #expect(!scheduler.sequences.isOpen(.scroll) && !scrolls.isOpen, "the momentum wait did not close it")

        let next = try Self.scroll(.began)
        let click = try Self.event(.leftMouseDown, at: 3)
        context.dispatching(next, in: window) {}
        #expect(scheduler.sequences.isOpen(.scroll))
        context.dispatching(click) {}
        #expect(!scheduler.sequences.isOpen(.scroll) && !scrolls.isOpen, "a click left the scroll sequence open")
    }
}

/// The windows a test's scroll sequences looked up a scheduler for.
@MainActor
private final class WindowLog {
    var windows: [NSWindow] = []
}

private final class DispatchTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
