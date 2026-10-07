import Foundation
import Testing
@testable import CmuxNextApps

/// The main-actor host: lazy start, mounts, routing, idle stop, logs.
/// Waits observe the host and the mount's model instead of polling them on a
/// deadline: under a loaded test process every main-actor hop can take
/// seconds, and a 30 s poll timed out with the engine still starting.
@Suite(.timeLimit(.minutes(2))) struct AppHostTests {
    @Test func mountRendersIntoTheModelAndTheLastUnmountStopsTheEngine() async throws {
        let (manifest, directory) = try TestApps.sample("running-agents")
        let sink = RecordingSink { request in
            request.op == "agent.list" ? .success(AppOperationResult(value: AppEngineTests.agents)) : .failure(.unsupported(request.op))
        }
        let host = AppHost(sink: sink, clock: ManualAppClock())
        let section = try #require(manifest.contributes.of(.sidebarSection).first)
        let mount = host.mount(manifest, directory: directory, contribution: section, surface: "sidebarSection")
        #expect(await observed { mount.model.scene.nodes.values.contains { $0.string("title") == "fix tests" } })
        #expect(mount.model.status == .ready)
        #expect(host.isRunning(manifest.id))
        host.unmount(mount)
        // The idle stop drops the engine before it logs, and `logs` is observable where the engine table is not.
        #expect(await observed { host.logs[manifest.id]?.contains { $0.message == "stopped: idle" } == true })
        #expect(!host.isRunning(manifest.id))
    }

    @Test func aStartFailureFailsTheMountWithTheReason() async throws {
        let (manifest, directory) = try TestApps.bundle(main: "throw new Error('broken main')")
        let host = AppHost(sink: RecordingSink(), clock: ManualAppClock())
        let contribution = AppContribution(kind: .sidebarSection, raw: ["id": "s", "title": "S", "render": "render"])
        let mount = host.mount(manifest, directory: directory, contribution: contribution, surface: "sidebarSection")
        #expect(await observed { if case .failed = mount.model.status { true } else { false } })
        if case .failed(let reason) = mount.model.status { #expect(reason.contains("broken main")) }
    }

    @Test func appLogsReachTheHostLog() async throws {
        let (manifest, directory) = try TestApps.bundle(main: "function hi() { cmux.log('hello', {a: 1}); return 1 } return { hi }")
        let host = AppHost(sink: RecordingSink(), clock: ManualAppClock())
        _ = await host.runCommand(manifest, directory: directory, export: "hi")
        #expect(await observed { host.logs[manifest.id]?.contains { $0.message == #"hello {"a":1}"# } == true })
    }
}

/// DisabledFeatures `apps`: the host refuses to start any app and stops running ones.
@Suite(.timeLimit(.minutes(2))) struct AppHostPolicyTests {
    @Test func aDisabledReasonRefusesStartsAndStopsRunningApps() async throws {
        let (manifest, directory) = try TestApps.bundle(main: "function hi() { return 1 } return { hi }")
        let host = AppHost(sink: RecordingSink(), clock: ManualAppClock())
        _ = await host.runCommand(manifest, directory: directory, export: "hi")
        #expect(host.isRunning(manifest.id))
        host.disabledReason = "Turned off by your organization"
        // `logs` is observable where the engine table is not.
        #expect(await observed { host.logs[manifest.id]?.contains { $0.message == "stopped: Turned off by your organization" } == true })
        #expect(!host.isRunning(manifest.id))
        guard case .failure(let error) = await host.runCommand(manifest, directory: directory, export: "hi") else {
            Issue.record("a disabled host ran an app")
            return
        }
        #expect(error.message == "Turned off by your organization")
        host.disabledReason = nil
        #expect(host.failures[manifest.id] == nil, "lifting the policy clears its failure")
        guard case .success = await host.runCommand(manifest, directory: directory, export: "hi") else {
            Issue.record("the host stayed disabled")
            return
        }
    }

    /// A start already running when apps are turned off does not keep the engine.
    @Test func aStartOvertakenByThePolicyDoesNotRun() async throws {
        let (manifest, directory) = try TestApps.bundle(main: "function hi() { return 1 } return { hi }")
        let host = AppHost(sink: RecordingSink(), clock: ManualAppClock())
        // task-owner: test-scoped start racing the policy below
        let run = Task { await host.runCommand(manifest, directory: directory, export: "hi") }
        host.disabledReason = "Turned off by your organization"
        _ = await run.value
        #expect(!host.isRunning(manifest.id))
    }
}

