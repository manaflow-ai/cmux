import Foundation
@testable import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextWakeups
import Testing

struct CloudEnvironmentBootstrapTests {
    @Test func knownBackendLaunchNeedsNoCLI() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let work = BackgroundWork()
        let bootstrap = CloudEnvironmentBootstrap(work: work, bundleID: "com.cmuxterm.app.debug.recovery",
            resources: nil, arguments: ["app", "--cloud-backend=staging"],
            environment: ["HOME": home.path, "CMUX_NEXT_CLOUD_BACKEND": "prod"])
        let result = try await bootstrap.resolve(cacheFirst: true)
        #expect(result.name == "staging")
        #expect(result.bundleId == "com.cmuxterm.app.debug.recovery")
        #expect(result.configSource == "known_origin_fallback")
        await work.shutdown()
    }

    @Test(arguments: [false, true]) func freshAndPersistedReadsKeepUsingCLI(persisted: Bool) async {
        let work = BackgroundWork()
        let bootstrap = CloudEnvironmentBootstrap(work: work, bundleID: "com.cmuxterm.app.debug.recovery",
            resources: nil, arguments: [], environment: ["HOME": "/unused"])
        await #expect(throws: DaemonError.launchFailed("The bundled cmux CLI is unavailable.")) {
            _ = try await bootstrap.resolve(persisted: persisted, cacheFirst: persisted)
        }
        await work.shutdown()
    }

    @Test func customUncachedBackendKeepsUsingCLI() async {
        let work = BackgroundWork()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bootstrap = CloudEnvironmentBootstrap(work: work, bundleID: "com.cmuxterm.app.debug.recovery",
            resources: nil, arguments: ["--cloud-backend=http://127.0.0.1:47653"], environment: ["HOME": home.path])
        await #expect(throws: DaemonError.launchFailed("The bundled cmux CLI is unavailable.")) {
            _ = try await bootstrap.resolve(cacheFirst: true)
        }
        await work.shutdown()
    }

    @Test func explicitSourceCLIStillOwnsItsResolver() async {
        let work = BackgroundWork()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bootstrap = CloudEnvironmentBootstrap(work: work, bundleID: "com.cmuxterm.app.debug.recovery",
            resources: nil, arguments: [],
            environment: ["HOME": home.path, DaemonLauncher.binaryOverrideKey: home.appendingPathComponent("cmux").path])
        await #expect(throws: DaemonError.launchFailed("The bundled cmux CLI is unavailable.")) {
            _ = try await bootstrap.resolve(cacheFirst: true)
        }
        await work.shutdown()
    }

    @Test func cancelledLaunchDoesNotReturnACachedSelection() async {
        let work = BackgroundWork()
        let bootstrap = CloudEnvironmentBootstrap(work: work, bundleID: "com.cmuxterm.app.debug.recovery",
            resources: nil, arguments: [], environment: ["HOME": "/unused"])
        // Owned and awaited here; cancel before the read without a scheduling race or sleep.
        let read = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await bootstrap.resolve(cacheFirst: true)
        }
        await #expect(throws: CancellationError.self) { _ = try await read.value }
        await work.shutdown()
    }
}
