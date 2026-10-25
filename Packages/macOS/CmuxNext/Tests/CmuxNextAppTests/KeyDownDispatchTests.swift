import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocusUI
import CmuxNextWakeups
import Testing

/// `ActionRegistry.isDispatchingKeyDown` decides whether a run is a key press: Copy with nothing
/// selected goes to the program for Cmd-C but is refused for a menu, palette or CLI Copy
/// (TerminalHandlers), and menu validation applies key-equivalent rules only to a key. The App
/// reads its input dispatch context (`InputDispatchContext`), never `NSApp.currentEvent`, which keeps the last key
/// after its dispatch: a CLI Copy after a key press would pass for Cmd-C.
@MainActor @Suite(.serialized)
struct KeyDownDispatchTests {
    @Test func aKeyWhoseDispatchEndedIsNoKeyDown() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                                characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        // AppKit's event queue (postEvent, then nextEvent, in any run loop mode) ended the whole
        // test process on the fleet's macOS 26 minis, so the stale key goes straight into the ivar
        // `currentEvent` returns, as a finished dispatch leaves it.
        try #require(class_getInstanceVariable(NSApplication.self, "_currentEvent") != nil,
                     "NSApplication has no _currentEvent ivar on this macOS")
        NSApp.setValue(key, forKey: "currentEvent")
        defer { NSApp.setValue(nil, forKey: "currentEvent") }
        try #require(NSApp.currentEvent?.type == .keyDown, "the test could not leave a stale key in currentEvent")
        #expect(!services.registry.isDispatchingKeyDown(), "a key whose dispatch ended counts as a key-down dispatch")
    }

    // MARK: The discrete-input signal (p06-scheduler-003)
    //
    // The main-thread scheduler hears each key-down and mouse-down from `InputDispatchContext` when its dispatch
    // ends, with whether the turn expects a frame (Chrome's `is_frame_expected_after_discrete_input`,
    // third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc): an applied or
    // waiting action effect, or a view that asked for display. Then automation work queued before the key
    // waits for the render pass of the next link tick, not the key's own commit.

    private static let catalog = [ActionDescriptor(id: "test.rename", title: "Rename", category: .other)]

    @Test func anAutomationPostQueuedBeforeAKeyRunsAfterTheNextTicksRenderPass() throws {
        _ = NSApplication.shared
        let clock = DiscreteInputClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let scheduler = MainWorkScheduler.testing(budget: budget) { _ in DiscreteInputFakeLink() }
        let context = InputDispatchContext(discreteInput: { scheduler.noteDiscreteInput(expectsFrame: $0) }, displayPending: { _ in false })
        let registry = ActionRegistry(catalog: Self.catalog)
        registry.effectExpectsFrame = { context.noteFrameExpected() }
        registry.bindEffect("test.rename", effect: { _ in .applied(ActionConfirmation(send: { nil })) })
        let automation = FrameBatchQueue(owner: "Control.frames", budgeted: .automation, on: scheduler)
        var ran = false
        automation.enqueue { ran = true }
        context.dispatching(try Self.key(.keyDown)) { _ = registry.perform("test.rename") }
        // The key's own turn ends with its own render pass: that pass does not end the response.
        scheduler.renderPassEnded(nanos: 1_000_000)
        clock.advance(ms: 17)
        scheduler.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(!ran, "automation ran in the tick before the key's frame was drawn")
        scheduler.renderPassEnded(nanos: 1_000_000)
        clock.advance(ms: 17)
        scheduler.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(ran, "automation still waited after the render pass of the tick after the key")
    }

    @Test func aKeyWhoseTurnExpectsNoFrameHoldsNothing() throws {
        _ = NSApplication.shared
        let clock = DiscreteInputClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let scheduler = MainWorkScheduler.testing(budget: budget) { _ in DiscreteInputFakeLink() }
        let context = InputDispatchContext(discreteInput: { scheduler.noteDiscreteInput(expectsFrame: $0) }, displayPending: { _ in false })
        let registry = ActionRegistry(catalog: Self.catalog)
        registry.effectExpectsFrame = { context.noteFrameExpected() }
        registry.bindEffect("test.rename", effect: { _ in .done })
        let automation = FrameBatchQueue(owner: "Control.frames", budgeted: .automation, on: scheduler)
        var ran = false
        automation.enqueue { ran = true }
        context.dispatching(try Self.key(.keyDown)) { _ = registry.perform("test.rename") }
        clock.advance(ms: 17)
        scheduler.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ran, "a key that changed nothing on screen held automation")
    }

    @Test func onlyKeyDownsAndMouseDownsReportAndANestedRedispatchReportsOnce() throws {
        _ = NSApplication.shared
        var reports: [Bool] = []
        var needsDisplay = false
        let context = InputDispatchContext(discreteInput: { reports.append($0) }, displayPending: { _ in needsDisplay })
        for event in [try Self.key(.keyUp), try Self.key(.flagsChanged), try Self.mouse(.mouseMoved), try Self.mouse(.leftMouseDragged)] {
            context.dispatching(event) { context.noteFrameExpected() }
        }
        #expect(reports.isEmpty, "a key-up, modifier change, move or drag reported a discrete input: \(reports)")
        let key = try Self.key(.keyDown)
        // `debug.key` dispatches its key and then sends the same event through the app.
        context.dispatching(key) { context.dispatching(key) { context.noteFrameExpected() } }
        #expect(reports == [true], "the outer dispatch did not keep the inner one's frame, or reported twice")
        needsDisplay = true
        context.dispatching(try Self.mouse(.leftMouseDown)) {}
        context.dispatching(try Self.mouse(.rightMouseDown)) {}
        needsDisplay = false
        context.dispatching(try Self.mouse(.otherMouseDown)) {}
        #expect(reports == [true, true, true, false], "a mouse-down's display request was not read")
        context.noteFrameExpected()
        #expect(reports.count == 4, "a frame noted between dispatches reported an input")
    }

    @Test func appliedAndWaitingEffectsExpectAFrameAndDoneAndRefusedDoNot() {
        var effect: ActionEffect = .done
        var expected = 0
        let registry = ActionRegistry(catalog: Self.catalog)
        registry.effectExpectsFrame = { expected += 1 }
        registry.bindEffect("test.rename", effect: { _ in effect })
        _ = registry.perform("test.rename")
        effect = .refused("no name", quiet: true)
        _ = registry.capturingRefusal { _ = registry.perform("test.rename") }
        #expect(expected == 0, "a done or refused effect expected a frame")
        effect = .applied(ActionConfirmation(send: { nil }))
        _ = registry.perform("test.rename")
        #expect(expected == 1, "an applied effect did not expect a frame")
        effect = .waiting(.daemonEcho, { nil }) // action-wait-allow: the test checks that the waiting kind expects a frame
        _ = registry.perform("test.rename")
        #expect(expected == 2, "a waiting effect did not expect a frame")
    }

    private static func key(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                      isARepeat: false, keyCode: 0))
    }

    private static func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class DiscreteInputClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [unowned self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

@MainActor
private final class DiscreteInputFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
