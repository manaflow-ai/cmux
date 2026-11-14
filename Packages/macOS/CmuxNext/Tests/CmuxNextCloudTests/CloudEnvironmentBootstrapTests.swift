import Foundation
@testable import CmuxNextCloud
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
}
