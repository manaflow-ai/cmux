import Foundation
import Testing

@testable import CmuxHooks

@Suite
struct EventHookDispatcherTests {
    @Test
    func runsHookWithEnvelopeAndExpandedArgs() async throws {
        let envelope = Data(#"{"name":"workspace.created","payload":{"cwd":"/tmp/x"}}"#.utf8)
        let runner = FakeHookProcessRunner(scripts: [.immediate(.successJSON("{}"))])
        let dispatcher = EventHookDispatcher(
            configState: { .loaded(try! Self.config()) },
            runner: runner,
            log: { _ in }
        )
        await dispatcher.dispatch(eventName: "workspace.created", envelopeJSON: envelope)
        try await completesWithin(seconds: 3) {
            await runner.waitForEventCount(2)
        }
        let invocation = try #require(await runner.recordedInvocations().first)
        #expect(invocation.stdin == envelope)
        #expect(invocation.arguments == ["/tmp/x"])
    }

    @Test
    func sameNameEventsSerializeDifferentNamesCanOverlap() async throws {
        let runner = FakeHookProcessRunner(scripts: [
            .delayed(label: "a1", result: .successJSON("{}")),
            .delayed(label: "b1", result: .successJSON("{}")),
            .delayed(label: "a2", result: .successJSON("{}")),
        ])
        let dispatcher = EventHookDispatcher(
            configState: { .loaded(try! Self.config(twoEvents: true)) },
            runner: runner,
            log: { _ in }
        )

        await dispatcher.dispatch(eventName: "workspace.created", envelopeJSON: Data(#"{"payload":{"cwd":"1"}}"#.utf8))
        await dispatcher.dispatch(eventName: "workspace.created", envelopeJSON: Data(#"{"payload":{"cwd":"2"}}"#.utf8))
        await dispatcher.dispatch(eventName: "surface.created", envelopeJSON: Data(#"{"payload":{"cwd":"3"}}"#.utf8))

        try await completesWithin(seconds: 3) {
            await runner.waitForEventCount(2)
        }
        let started = await runner.recordedEvents()
        #expect(started.contains("start:a1"))
        #expect(started.contains("start:b1"))
        #expect(!started.contains("start:a2"))

        try await completesWithin(seconds: 3) {
            await runner.waitForEventCount(6)
        }
        let events = await runner.recordedEvents()
        let startA1 = try #require(events.firstIndex(of: "start:a1"))
        let finishA1 = try #require(events.firstIndex(of: "finish:a1"))
        let startA2 = try #require(events.firstIndex(of: "start:a2"))
        let startB1 = try #require(events.firstIndex(of: "start:b1"))
        #expect(startA1 < finishA1)
        #expect(finishA1 < startA2)
        #expect(startB1 < finishA1)
    }

    @Test
    func failuresLogAndDoNotStopLaterDispatches() async throws {
        final actor LogBox {
            var lines: [String] = []
            func append(_ line: String) { lines.append(line) }
            func all() -> [String] { lines }
        }
        let logs = LogBox()
        let runner = FakeHookProcessRunner(scripts: [
            .immediate(.failure(exitStatus: 5)),
            .immediate(.successJSON("{}")),
        ])
        let dispatcher = EventHookDispatcher(
            configState: { .loaded(try! Self.config()) },
            runner: runner,
            log: { line in Task { await logs.append(line) } }
        )
        await dispatcher.dispatch(eventName: "workspace.created", envelopeJSON: Data(#"{"payload":{"cwd":"1"}}"#.utf8))
        await dispatcher.dispatch(eventName: "workspace.created", envelopeJSON: Data(#"{"payload":{"cwd":"2"}}"#.utf8))
        try await completesWithin(seconds: 3) {
            await runner.waitForEventCount(4)
        }
        #expect(await runner.recordedInvocations().count == 2)
        #expect(await logs.all().contains { $0.contains("exited non-zero") })
    }

    @Test
    func ignoresHookPrefixDisabledAbsentAndBroken() async throws {
        let envelope = Data(#"{"payload":{"cwd":"1"}}"#.utf8)
        let runner = FakeHookProcessRunner(scripts: [])
        let dispatcher = EventHookDispatcher(
            configState: { .loaded(try! Self.config(disabled: true)) },
            runner: runner,
            log: { _ in }
        )
        await dispatcher.dispatch(eventName: "workspace.created", envelopeJSON: envelope)
        await dispatcher.dispatch(eventName: "hook.spawn.denied", envelopeJSON: envelope)
        #expect(await runner.recordedInvocations().isEmpty)

        let absent = EventHookDispatcher(configState: { .absent }, runner: runner, log: { _ in })
        await absent.dispatch(eventName: "workspace.created", envelopeJSON: envelope)
        let broken = EventHookDispatcher(configState: { .broken(reason: "bad") }, runner: runner, log: { _ in })
        await broken.dispatch(eventName: "workspace.created", envelopeJSON: envelope)
        #expect(await runner.recordedInvocations().isEmpty)
    }

    @Test
    func subscribedEventNamesOnlyEnabledLoadedHooks() async throws {
        let dispatcher = EventHookDispatcher(
            configState: { .loaded(try! Self.config(disabled: true, includeEnabledSurface: true)) },
            runner: FakeHookProcessRunner(scripts: []),
            log: { _ in }
        )
        #expect(await dispatcher.subscribedEventNames() == ["surface.created"])
    }

    private static func config(
        disabled: Bool = false,
        includeEnabledSurface: Bool = false,
        twoEvents: Bool = false
    ) throws -> CmuxHooksConfig {
        let workspaceHook = try CmuxHookDefinition(
            command: disabled ? "/bin/disabled" : "a1",
            args: ["${event.payload.cwd}"],
            enabled: !disabled
        )
        var events = ["workspace.created": [workspaceHook]]
        if includeEnabledSurface || twoEvents {
            events["surface.created"] = [try CmuxHookDefinition(command: "b1")]
        }
        return CmuxHooksConfig(events: events)
    }
}
