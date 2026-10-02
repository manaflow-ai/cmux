import Foundation
import Testing
@testable import CmuxNextApps

/// The main-actor host: lazy start, mounts, routing, idle stop, logs.
struct AppHostTests {
    @Test func mountRendersIntoTheModelAndTheLastUnmountStopsTheEngine() async throws {
        let (manifest, directory) = try TestApps.sample("running-agents")
        let sink = RecordingSink { request in
            request.op == "agent.list" ? .success(AppOperationResult(value: AppEngineTests.agents)) : .failure(.unsupported(request.op))
        }
        let host = AppHost(sink: sink, clock: ManualAppClock())
        let section = try #require(manifest.contributes.of(.sidebarSection).first)
        let mount = host.mount(manifest, directory: directory, contribution: section, surface: "sidebarSection")
        #expect(await eventually { await MainActor.run { mount.model.scene.nodes.values.contains { $0.string("title") == "fix tests" } } })
        #expect(mount.model.status == .ready)
        #expect(host.isRunning(manifest.id))
        host.unmount(mount)
        #expect(await eventually { await MainActor.run { !host.isRunning(manifest.id) } })
    }

    @Test func aStartFailureFailsTheMountWithTheReason() async throws {
        let (manifest, directory) = try TestApps.bundle(main: "throw new Error('broken main')")
        let host = AppHost(sink: RecordingSink(), clock: ManualAppClock())
        let contribution = AppContribution(kind: .sidebarSection, raw: ["id": "s", "title": "S", "render": "render"])
        let mount = host.mount(manifest, directory: directory, contribution: contribution, surface: "sidebarSection")
        #expect(await eventually { await MainActor.run { if case .failed = mount.model.status { true } else { false } } })
        if case .failed(let reason) = mount.model.status { #expect(reason.contains("broken main")) }
    }

    @Test func appLogsReachTheHostLog() async throws {
        let (manifest, directory) = try TestApps.bundle(main: "function hi() { cmux.log('hello', {a: 1}); return 1 } return { hi }")
        let host = AppHost(sink: RecordingSink(), clock: ManualAppClock())
        _ = await host.runCommand(manifest, directory: directory, export: "hi")
        #expect(await eventually { await MainActor.run { host.logs[manifest.id]?.contains { $0.message == #"hello {"a":1}"# } == true } })
    }
}
