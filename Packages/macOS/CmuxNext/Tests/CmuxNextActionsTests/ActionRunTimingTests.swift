import AppKit
@testable import CmuxNextActions
import Testing

/// Records each timed run instead of writing signposts, and whether work ran inside the timing.
@MainActor
private final class RunTimingRecorder: ActionRunTiming {
    struct Run: Equatable {
        let id: ActionID
        let origin: ActionOrigin
        let inputAge: Double
    }

    var runs: [Run] = []
    private(set) var isTiming = false
    /// For each handler run: whether it ran inside the timing.
    var handlerRanTimed: [Bool] = []
    /// Key window route runs.
    var routed = 0

    func time<T>(_ id: ActionID, _ origin: ActionOrigin, inputAge: () -> Double, _ body: () -> T) -> T {
        runs.append(Run(id: id, origin: origin, inputAge: inputAge()))
        isTiming = true
        defer { isTiming = false }
        return body()
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
}
