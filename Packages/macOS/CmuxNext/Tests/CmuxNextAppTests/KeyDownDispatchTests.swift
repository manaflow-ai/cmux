import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemonService
@testable import CmuxNextFocusUI
@testable import CmuxNextTerminal
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
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

    // MARK: The discrete-input signal
    //
    // The main-thread scheduler hears each discrete input from `InputDispatchContext` (key-down, mouse-down, and a
    // mouse-up whose turn expects a frame), with whether the turn expects a frame (Chrome's
    // `is_frame_expected_after_discrete_input`, third_party/blink/renderer/platform/scheduler/main_thread/
    // main_thread_scheduler_impl.cc): an action ran, a view asked for display, or the terminal took the key. Then
    // automation work queued before the input waits for the render pass of the next link tick, not the input's own.

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
        // A frame client keeps the link running, so the post waits for a frame instead of the next turn.
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: scheduler.frames) { _ in true }
        keeper.activate()
        defer { keeper.deactivate() }
        var ran = false
        scheduler.post(.automation, owner: "cli.request") { ran = true }
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
        // The handler's guard bailed: nothing changed on screen.
        registry.bindEffect("test.rename", effect: { _ in .refused("no name", quiet: true) })
        // A frame client keeps the link running, so the post waits for a frame instead of the next turn.
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: scheduler.frames) { _ in true }
        keeper.activate()
        defer { keeper.deactivate() }
        var ran = false
        scheduler.post(.automation, owner: "cli.request") { ran = true }
        context.dispatching(try Self.key(.keyDown)) { _ = registry.capturingRefusal { _ = registry.perform("test.rename") } }
        clock.advance(ms: 17)
        scheduler.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ran, "a key whose action was refused held automation")
    }

    @Test func keyAndMouseDownsAlwaysReportMouseUpsOnlyWithAFrameAndANestedRedispatchReportsOnce() throws {
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
        // A release that changed nothing reports nothing; a button that acts on release reports its frame.
        context.dispatching(try Self.mouse(.leftMouseUp)) {}
        #expect(reports.count == 4, "a mouse-up that changed nothing reported a discrete input")
        context.dispatching(try Self.mouse(.leftMouseUp)) { context.noteFrameExpected() }
        #expect(reports == [true, true, true, false, true], "a mouse-up whose action ran did not report its frame")
        context.noteFrameExpected()
        #expect(reports.count == 5, "a frame noted between dispatches reported an input")
    }

    @Test func anActionRunInAMouseUpOpensTheInputResponse() throws {
        _ = NSApplication.shared
        let clock = DiscreteInputClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let context = InputDispatchContext(discreteInput: { budget.noteDiscreteInput(expectsFrame: $0) }, displayPending: { _ in false })
        let registry = ActionRegistry(catalog: Self.catalog)
        registry.effectExpectsFrame = { context.noteFrameExpected() }
        registry.bindEffect("test.rename", effect: { _ in .applied(ActionConfirmation(send: { nil })) })
        context.dispatching(try Self.mouse(.leftMouseDown)) {}
        #expect(!budget.isInputResponseOpen, "a mouse-down that changed nothing opened the input response")
        // A SwiftUI Button runs its action on release.
        context.dispatching(try Self.mouse(.leftMouseUp)) { _ = registry.perform("test.rename") }
        #expect(budget.isInputResponseOpen, "the click's action ran on release, and automation was not held for its frame")
    }

    @Test func aDiscreteInputReportsAtTheFirstWaitOfARunLoopNestedInIt() throws {
        _ = NSApplication.shared
        var reports: [Bool] = []
        let context = InputDispatchContext(discreteInput: { reports.append($0) }, displayPending: { _ in false })
        // A mouse-down that opens a menu or starts a drag tracks in a nested run loop, which draws its frames:
        // the click reports there, before the loop's first commit, not when the tracking ends.
        context.dispatching(try Self.mouse(.leftMouseDown)) {
            context.noteFrameExpected()
            let timer = Timer(timeInterval: 0.005, repeats: false) { _ in }
            RunLoop.current.add(timer, forMode: .default)
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1))
            #expect(reports == [true], "the click did not report before the nested run loop waited: \(reports)")
        }
        #expect(reports == [true], "the click reported again when its dispatch ended: \(reports)")
        // A key that reported no frame at a nested wait reports again when its dispatch later expects one.
        reports = []
        context.dispatching(try Self.key(.keyDown)) {
            context.nestedRunLoopWillWait()
            context.noteFrameExpected()
        }
        #expect(reports == [false, true], "a frame expected after the nested wait was not reported: \(reports)")
    }

    /// The input-response pass must be on the run loop for the whole discrete dispatch (a nested run loop's first
    /// wait included): the context says when the first discrete dispatch begins, before its body, and when the last
    /// one ends, after its report.
    @Test func theFirstDiscreteDispatchIsAnnouncedBeforeItsBodyAndTheLastEndsAfterItsReport() throws {
        _ = NSApplication.shared
        var log: [String] = []
        let context = InputDispatchContext(discreteInput: { log.append("report \($0)") },
                                           discreteDispatch: { log.append($0 ? "began" : "ended") },
                                           displayPending: { _ in false })
        context.dispatching(try Self.key(.keyUp)) {}
        #expect(log.isEmpty, "a key-up was announced as a discrete dispatch: \(log)")
        let click = try Self.mouse(.leftMouseDown)
        context.dispatching(try Self.key(.keyDown)) {
            log.append("body")
            // A click dispatched inside the key's dispatch: one span for both.
            context.dispatching(click) {}
            context.noteFrameExpected()
        }
        #expect(log == ["began", "body", "report false", "report true", "ended"], "\(log)")
    }

    @Test func doneAppliedWaitingAndUntypedRunsExpectAFrameAndRefusedDoesNot() {
        var effect: ActionEffect = .refused("no name", quiet: true)
        var expected = 0
        let registry = ActionRegistry(catalog: Self.catalog + [ActionDescriptor(id: "test.legacy", title: "Legacy", category: .other)])
        registry.effectExpectsFrame = { expected += 1 }
        registry.bindEffect("test.rename", effect: { _ in effect })
        registry.bind("test.legacy", handler: {})
        _ = registry.capturingRefusal { _ = registry.perform("test.rename") }
        #expect(expected == 0, "a refused effect expected a frame")
        // `.done`: the whole change (a selection, a focus move, a view toggle) happened on the turn.
        effect = .done
        _ = registry.perform("test.rename")
        #expect(expected == 1, "a done effect did not expect a frame")
        effect = .applied(ActionConfirmation(send: { nil }))
        _ = registry.perform("test.rename")
        #expect(expected == 2, "an applied effect did not expect a frame")
        effect = .waiting(.daemonEcho, { nil }) // action-wait-allow: the test checks that the waiting kind expects a frame
        _ = registry.perform("test.rename")
        #expect(expected == 3, "a waiting effect did not expect a frame")
        _ = registry.perform("test.legacy")
        #expect(expected == 4, "an untyped handler run did not expect a frame")
    }

    /// The App's wiring: `AppServices` hands its scheduler's `noteDiscreteInput` to its input dispatch context, and the
    /// context's `noteFrameExpected` to the registry and the terminals' delegate.
    @Test func theAppsInputDispatchOpensItsSchedulersInputResponse() throws {
        _ = NSApplication.shared
        let clock = DiscreteInputClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let scheduler = MainWorkScheduler.testing(budget: budget) { _ in DiscreteInputFakeLink() }
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: scheduler)
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: scheduler.frames) { _ in true }
        keeper.activate()
        defer { keeper.deactivate() }
        // An event in no window: no view's display request makes the frame expected.
        services.inputDispatch.dispatching(try Self.key(.keyDown)) {
            #expect(budget.isDiscreteDispatchOpen, "the app's key dispatch did not tell its scheduler it began")
            services.registry.settle(.done, of: "test.rename", ActionInvocation())
        }
        #expect(!budget.isDiscreteDispatchOpen, "the app's key dispatch did not tell its scheduler it ended")
        #expect(budget.isInputResponseOpen, "an action run in the app's key dispatch did not open the input response")
        scheduler.renderPassEnded(nanos: 1_000_000)
        #expect(budget.isInputResponseOpen, "the key's own render pass ended its input response")
        clock.advance(ms: 17)
        scheduler.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        scheduler.renderPassEnded(nanos: 1_000_000)
        #expect(!budget.isInputResponseOpen, "the next tick's render pass did not end the input response")
        // A key the terminal took, reported through the app's terminal delegate.
        clock.advance(ms: 200)
        let io = ScriptedTerminalIO()
        defer { io.finish() }
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        services.inputDispatch.dispatching(try Self.key(.keyDown)) {
            services.terminalDelegate.terminalSessionTookKey(session)
        }
        #expect(budget.isInputResponseOpen, "a key the terminal took did not open the app's input response")
    }

    /// `debug.key` into a window that is not key (`CMUX_NEXT_NO_ACTIVATE=1`, the fleet benches) sends its key with
    /// `NSWindow.sendEvent`, off `CmuxApplication.sendEvent`: the terminal still reports the key it took.
    @Test func aKeyTheTerminalTookExpectsAFrameOffTheAppsSendEvent() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let taken = TookKeys()
        session.delegate = taken
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        session.view.layoutSubtreeIfNeeded()
        defer {
            io.finish()
            window.close()
        }
        try #require(window.makeFirstResponder(session.surfaceView), "the terminal never took the keyboard")
        var reports: [Bool] = []
        let context = InputDispatchContext(discreteInput: { reports.append($0) }, displayPending: { _ in false })
        taken.onTake = { context.noteFrameExpected() }
        let down = try Self.key(.keyDown, window: window)
        context.dispatching(down) { window.sendEvent(down) }
        #expect(reports == [true], "a key the terminal took off the app's sendEvent expected no frame: \(reports)")
        #expect(taken.count == 1, "the terminal reported \(taken.count) taken keys for one key-down")
        let up = try Self.key(.keyUp, window: window)
        context.dispatching(up) { window.sendEvent(up) }
        #expect(taken.count == 1, "the key's release was reported as a key the terminal took")
    }

    /// A client that pipelines `debug.key` requests on one connection: each key is the head of its connection once the
    /// one before it ran, and runs on the next input turn. The input response and the typing burst its keys start
    /// hold automation (one task per 100 ms), never the keys: behind its first key the others used to wait for
    /// automation frames, each for the response and the burst slot the key before it opened.
    @Test func pipelinedInjectedKeysNeverWaitForTheInputResponseTheyOpen() {
        let clock = DiscreteInputClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let scheduler = MainWorkScheduler.testing(budget: budget, clock: ManualClock()) { _ in DiscreteInputFakeLink() }
        let batcher = FrameBatcher(owner: "Control.frames", budgeted: .automation, on: scheduler)
        let queue = MainActorWorkQueue(frameSource: batcher)
        let deadline = ContinuousClock.now + .seconds(30)
        let end = ContinuousClock.now + .seconds(10)
        let keys = 4
        for _ in 0..<keys {
            Task.detached {
                _ = try await queue.run(connection: ControlConnectionID(rawValue: 7), method: "debug.key", workClass: .input, deadline: deadline) {
                    scheduler.noteDiscreteInput(expectsFrame: true)  // each key echoes in the terminal
                }
            }
        }
        while queue.stats.pending + queue.stats.executed < keys, ContinuousClock.now < end { usleep(1_000) }
        // No display frame fires and the budget's clock stands still: only main run loop turns.
        while queue.stats.executed < keys, ContinuousClock.now < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
        #expect(queue.stats.executed == keys, "\(keys - queue.stats.executed) pipelined keys waited for an automation frame")
    }

    private static func key(_ type: NSEvent.EventType, window: NSWindow? = nil) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window?.windowNumber ?? 0, context: nil, characters: "a",
                                      charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
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

/// Counts the keys a terminal took (`TerminalSessionDelegate.terminalSessionTookKey`).
@MainActor
private final class TookKeys: TerminalSessionDelegate {
    private(set) var count = 0
    var onTake: () -> Void = {}

    func terminalSessionTookKey(_ session: TerminalSession) {
        count += 1
        onTake()
    }
}

@MainActor
private final class DiscreteInputFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
