import AppKit
@testable import CmuxNextActions
import Testing

/// Records each timed run and gate instead of writing signposts, whether work ran inside a run's
/// timing, and the order intervals begin and end in (`events`), so a test can see nesting.
@MainActor
private final class RunTimingRecorder: ActionRunTiming {
    struct Run: Equatable {
        let id: ActionID
        let origin: ActionOrigin
        let inputAge: Double
        let entrypoint: ActionEntrypoint
    }

    var runs: [Run] = []
    var gates: [Run] = []
    /// `run.begin id`, `run.end id`, `gate.begin id`, `gate.end id`, in order.
    var events: [String] = []
    private(set) var isTiming = false
    /// For each handler run: whether it ran inside the timing.
    var handlerRanTimed: [Bool] = []
    /// Key window route runs.
    var routed = 0

    func intern(_ id: ActionID) -> UInt32 { 0 }

    func time<T>(_ key: ActionRunKey, _ origin: ActionOrigin, input: () -> ActionRunInput, _ body: () -> T) -> T {
        let id = key.id
        let read = input()
        runs.append(Run(id: id, origin: origin, inputAge: read.ageMilliseconds, entrypoint: read.entrypoint))
        events.append("run.begin \(id.rawValue)")
        let wasTiming = isTiming
        isTiming = true
        defer {
            isTiming = wasTiming
            events.append("run.end \(id.rawValue)")
        }
        return body()
    }

    func beginGate(_ id: ActionID, _ origin: ActionOrigin, input: () -> ActionRunInput) -> (@MainActor () -> Void)? {
        let read = input()
        gates.append(Run(id: id, origin: origin, inputAge: read.ageMilliseconds, entrypoint: read.entrypoint))
        events.append("gate.begin \(id.rawValue)")
        return { [weak self] in self?.events.append("gate.end \(id.rawValue)") }
    }
}

/// `action.perform` / `action.commit` (ActionRegistry+Signposts): every run that does work is
/// timed, and only a person's run inside an input event's dispatch carries that event's age.
@MainActor
@Suite struct ActionRunTimingTests {
    private static func key(at timestamp: TimeInterval) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp,
                                             windowNumber: 0, context: nil, characters: "a",
                                             charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    }

    private static func registry(_ recorder: RunTimingRecorder) -> ActionRegistry {
        let registry = ActionRegistry(catalog: [], runTiming: recorder)
        registry.register(Action(id: "test.run", title: "Run") { [weak recorder] in
            guard let recorder else { return }
            recorder.handlerRanTimed.append(recorder.isTiming)
        })
        registry.register(Action(id: "test.off", title: "Off", isEnabled: { false }) {})
        return registry
    }

    @Test func aHandlerRunsInsideTheTiming() {
        let recorder = RunTimingRecorder()
        let registry = Self.registry(recorder)
        #expect(registry.perform("test.run"))
        #expect(recorder.runs.map(\.id) == ["test.run"])
        #expect(recorder.handlerRanTimed == [true])
    }

    @Test func aRefusedRunIsNotTimed() {
        let recorder = RunTimingRecorder()
        let registry = Self.registry(recorder)
        #expect(!registry.perform("test.off"))
        #expect(!registry.perform("test.unbound"))
        #expect(recorder.runs.isEmpty)
    }

    @Test func aKeyWindowRouteRunIsTimedAndARouteRefusalIsNot() {
        let recorder = RunTimingRecorder()
        let registry = Self.registry(recorder)
        registry.keyWindowRoute = { [weak recorder] id, _ in
            id == "settings.close" ? .run { recorder?.routed += 1 } : .disabled(reason: "not here")
        }
        #expect(registry.perform("settings.close"))
        #expect(!registry.perform("test.run"))
        #expect(recorder.routed == 1)
        #expect(recorder.runs.map(\.id) == ["settings.close"])
    }

    @Test func aCLIRunHasNoInputAgeWhileAKeyIsBeingDispatched() throws {
        let recorder = RunTimingRecorder()
        let registry = Self.registry(recorder)
        let key = try Self.key(at: ProcessInfo.processInfo.systemUptime - 0.005)
        registry.dispatchingInputEvent = { key }
        #expect(registry.perform("test.run", invocation: ActionInvocation(origin: .cli)))
        #expect(registry.perform("test.run", invocation: ActionInvocation(origin: .user)))
        #expect(recorder.runs.map(\.origin) == [.cli, .user])
        #expect(recorder.runs.first?.inputAge == -1)
        #expect((recorder.runs.last?.inputAge ?? -1) >= 5)
    }

    /// The budget is kept per entrypoint: a person's key, a person's click, a person's run with no
    /// event being dispatched, and every other origin by itself.
    @Test func eachRunNamesItsEntrypoint() throws {
        _ = NSApplication.shared
        let recorder = RunTimingRecorder()
        let registry = Self.registry(recorder)
        let key = try Self.key(at: ProcessInfo.processInfo.systemUptime)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        var dispatching: NSEvent? = key
        registry.dispatchingInputEvent = { dispatching }
        #expect(registry.perform("test.run"))
        dispatching = click
        #expect(registry.perform("test.run"))
        #expect(registry.perform("test.run", invocation: ActionInvocation(origin: .cli)))
        dispatching = nil
        #expect(registry.perform("test.run"))
        #expect(registry.perform("test.run", invocation: ActionInvocation(origin: .page)))
        #expect(recorder.runs.map(\.entrypoint) == [.key, .pointer, .cli, .unattributed, .page])
    }

    @Test func aUserRunOutsideADispatchHasNoInputAge() {
        let recorder = RunTimingRecorder()
        let registry = Self.registry(recorder)
        #expect(registry.perform("test.run"))
        #expect(recorder.runs.map(\.inputAge) == [-1])
    }

    @Test(arguments: ActionOrigin.allCases)
    func onlyAPersonsRunCarriesTheEventsAge(_ origin: ActionOrigin) throws {
        let age = ActionRegistry.inputAgeMilliseconds(origin: origin, event: try Self.key(at: 100), now: 100.25)
        #expect(age == (origin == .user ? 250 : -1))
    }

    @Test func noEventOrAnEventThatIsNoKeyOrClickHasNoAge() throws {
        _ = NSApplication.shared
        let move = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 100,
                                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        #expect(ActionRegistry.inputAgeMilliseconds(origin: .user, event: move, now: 101) == -1)
        #expect(ActionRegistry.inputAgeMilliseconds(origin: .user, event: nil, now: 101) == -1)
    }

    // MARK: Gates (confirmation, argument collection)

    private static let gatedCatalog = [
        ActionDescriptor(id: "closeWorkspace", title: "Close Workspace", category: .other, destructive: true),
        ActionDescriptor(id: "tabGroup.close", title: "Close Group", category: .other, destructive: true),
        ActionDescriptor(id: "test.ask", title: "Ask", category: .other,
                         arguments: [ActionArgument(name: "name", title: "Name", kind: .string)]),
    ]

    private static func gatedRegistry(_ recorder: RunTimingRecorder, ran: @escaping @MainActor (ActionID, ActionInvocation) -> Void) -> ActionRegistry {
        let registry = ActionRegistry(catalog: gatedCatalog, runTiming: recorder)
        for descriptor in gatedCatalog {
            let id = descriptor.id
            registry.bind(id, invoke: { ran(id, $0) })
        }
        return registry
    }

    /// The App's Close Workspace presenter runs the confirmed close at once, inside the gate
    /// (DestructiveConfirmation): one press is one run, and the gate does not enclose it.
    @Test func aPresenterThatRunsAtOnceGivesOneRunAndNoNesting() throws {
        let recorder = RunTimingRecorder()
        var closes = 0
        let registry = Self.gatedRegistry(recorder) { id, _ in if id == "closeWorkspace" { closes += 1 } }
        registry.confirmationPresenter = { [unowned registry] id, invocation, _ in
            registry.perform(id, invocation: invocation.confirmed())
        }
        let key = try Self.key(at: ProcessInfo.processInfo.systemUptime - 0.005)
        registry.dispatchingInputEvent = { key }
        #expect(registry.perform("closeWorkspace"))
        #expect(closes == 1)
        #expect(recorder.runs.map(\.id) == ["closeWorkspace"], "one press timed as \(recorder.runs.count) runs")
        #expect(recorder.gates.map(\.id) == ["closeWorkspace"])
        #expect(recorder.events == ["gate.begin closeWorkspace", "gate.end closeWorkspace",
                                    "run.begin closeWorkspace", "run.end closeWorkspace"])
        #expect((recorder.runs.first?.inputAge ?? -1) >= 5)
    }

    /// Group close confirms in a later turn (a `Task` awaiting the daemon): that run happens
    /// outside the key's dispatch and still reports the key's age, carried in the invocation.
    @Test func aRunConfirmedInALaterTurnReportsThePressesAge() throws {
        let recorder = RunTimingRecorder()
        var closes: [ActionInvocation] = []
        let registry = Self.gatedRegistry(recorder) { id, invocation in if id == "tabGroup.close" { closes.append(invocation) } }
        var pending: (@MainActor () -> Void)?
        registry.confirmationPresenter = { _, _, proceed in pending = { proceed(false) } }
        let key = try Self.key(at: ProcessInfo.processInfo.systemUptime - 0.005)
        var dispatching: NSEvent? = key
        registry.dispatchingInputEvent = { dispatching }
        #expect(registry.perform("tabGroup.close"))
        #expect(recorder.runs.isEmpty, "the gate was timed as a run of the action")
        #expect(recorder.gates.map(\.id) == ["tabGroup.close"])

        dispatching = nil  // the key's dispatch ended; the daemon answered later
        let proceed = try #require(pending)
        proceed()
        #expect(closes.count == 1)
        #expect(closes.first?.isConfirmed == true)
        #expect(closes.first?.inputTimestamp == nil, "the handler got the press: a follow-up action would report its age")
        #expect(recorder.runs.map(\.id) == ["tabGroup.close"])
        #expect((recorder.runs.first?.inputAge ?? -1) >= 5, "the confirmed run lost the press's age")
    }

    /// The palette opening for a missing argument is a gate; the run after it is a run.
    @Test func collectingArgumentsIsAGateNotARun() throws {
        let recorder = RunTimingRecorder()
        var ran: [ActionID] = []
        let registry = Self.gatedRegistry(recorder) { id, _ in ran.append(id) }
        var collected: [ActionInvocation] = []
        registry.argumentCollector = { _, invocation in collected.append(invocation) }
        #expect(registry.perform("test.ask"))
        #expect(recorder.runs.isEmpty)
        #expect(recorder.gates.map(\.id) == ["test.ask"])
        var full = try #require(collected.first)
        full.arguments["name"] = .string("x")
        #expect(registry.perform("test.ask", invocation: full))
        #expect(ran == ["test.ask"])
        #expect(recorder.runs.map(\.id) == ["test.ask"])
    }

    /// A socket run carries no stamp, even one copied from a person's run: only a person's run
    /// reports an age.
    @Test func aCarriedStampCountsOnlyForAPersonsRun() {
        #expect(ActionRegistry.inputAgeMilliseconds(origin: .user, event: nil, carried: 100, now: 100.5) == 500)
        #expect(ActionRegistry.inputAgeMilliseconds(origin: .cli, event: nil, carried: 100, now: 100.5) == -1)
    }

    /// After a question the confirmed run answers the answer, not the press: a click on the sheet
    /// gives that click's age; an answer outside any dispatch gives -1, never the press's age with
    /// the person's reading time in it.
    @Test func aRunConfirmedAfterAQuestionReportsTheAnswersAgeNotThePresses() throws {
        let recorder = RunTimingRecorder()
        var closes: [ActionInvocation] = []
        let registry = Self.gatedRegistry(recorder) { id, invocation in if id == "tabGroup.close" { closes.append(invocation) } }
        var pending: (@MainActor (Bool) -> Void)?
        registry.confirmationPresenter = { _, _, proceed in pending = proceed }
        let now = ProcessInfo.processInfo.systemUptime
        var dispatching: NSEvent? = try Self.key(at: now - 3)  // the press; the person then reads for 3 s
        registry.dispatchingInputEvent = { dispatching }
        #expect(registry.perform("tabGroup.close"))
        let proceed = try #require(pending)

        dispatching = try Self.key(at: now - 0.002)  // the sheet's button, being dispatched
        proceed(true)
        let answered: Double = try #require(recorder.runs.last?.inputAge)
        #expect(answered >= 1, "the run reported \(answered) ms, not the answer's age")
        #expect(answered < 1_000, "the run reported \(answered) ms: the press's age with the reading time")

        #expect(registry.perform("tabGroup.close"))
        dispatching = nil  // answered outside any dispatch
        let secondProceed = try #require(pending)
        secondProceed(true)
        let unanswered = recorder.runs.last?.inputAge
        #expect(unanswered == -1)
        #expect(closes.count == 2)
        let confirmed = closes.filter { $0.isConfirmed }
        #expect(confirmed.count == 2)
    }

    /// A nested loop counts as the person's dwell only in a mode a person drives (a menu's event
    /// tracking, a modal panel). A handler that spins the default mode waiting for a helper's reply is a
    /// stall: its wakes stay out of the count, so its sample stays in action.perform / action.commit.
    @Test func onlyAPersonDrivenNestedLoopCountsAsDwell() {
        func spin(_ mode: CFRunLoopMode) {
            let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.02, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetMain(), timer, mode)
            _ = CFRunLoopRunInMode(mode, 1, true)
            CFRunLoopTimerInvalidate(timer)
        }
        let watch = RunLoopWakeWatch()
        watch.begin()
        spin(.defaultMode)
        #expect(watch.wakes == 0, "a default-mode wait inside a handler counted as the person's dwell")
        spin(CFRunLoopMode("NSEventTrackingRunLoopMode" as CFString))
        #expect(watch.wakes >= 1, "a menu's event-tracking loop was not counted")
        watch.end()
        let after = watch.wakes
        spin(CFRunLoopMode("NSEventTrackingRunLoopMode" as CFString))
        #expect(watch.wakes == after, "an ended watch still counted")
    }

    // MARK: Previews

    /// Running another action while a preview shows puts the look back inside the run's timing
    /// (the person waits for it); a refused run reverts too, and records nothing.
    @Test func revertingAPreviewIsPartOfTheRun() {
        let recorder = RunTimingRecorder()
        let registry = Self.registry(recorder)
        registry.register(Action(id: "test.style", title: "Style") {})
        var revertedTimed: [Bool] = []
        registry.bindPreview("test.style", ActionPreview(group: "style") { { [weak recorder] in revertedTimed.append(recorder?.isTiming ?? false) } })

        registry.showPreview("test.style")
        #expect(registry.perform("test.run"))
        #expect(revertedTimed == [true], "the revert ran outside the run's timing")

        registry.showPreview("test.style")
        #expect(!registry.perform("test.off"))
        #expect(revertedTimed == [true, false])
        #expect(recorder.runs.map(\.id) == ["test.run"])
    }

    // MARK: Key-down dispatch

    /// `NSApp.currentEvent` keeps a key after its dispatch: the package default must not read it,
    /// or a CLI Copy after a key press passes for Cmd-C (TerminalHandlers) and menu validation
    /// applies key-equivalent rules to a click.
    @Test func aStaleKeyIsNoKeyDownDispatch() throws {
        _ = NSApplication.shared
        let key = try Self.key(at: ProcessInfo.processInfo.systemUptime)
        // AppKit's event queue (postEvent, then nextEvent, in any run loop mode) ended the whole
        // test process on the fleet's macOS 26 minis, so the stale key goes straight into the ivar
        // `currentEvent` returns, as a finished dispatch leaves it.
        try #require(class_getInstanceVariable(NSApplication.self, "_currentEvent") != nil,
                     "NSApplication has no _currentEvent ivar on this macOS")
        NSApp.setValue(key, forKey: "currentEvent")
        defer { NSApp.setValue(nil, forKey: "currentEvent") }
        try #require(NSApp.currentEvent?.type == .keyDown, "the test could not leave a stale key in currentEvent")
        #expect(!ActionRegistry().isDispatchingKeyDown())
    }
}
