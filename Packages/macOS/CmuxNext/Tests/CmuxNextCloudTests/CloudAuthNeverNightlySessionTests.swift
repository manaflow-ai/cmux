import CMUXAuthCore
import CmuxAuthRuntime
@testable import CmuxNextCloud
import Foundation
import Testing

/// Regression (2026-11-18): no dev build takes cmux NIGHTLY's signed-in session. The production cloud-api ignores
/// `X-Cmux-Build-Space`, so a dev build on NIGHTLY's session would read and write NIGHTLY's real data. A tagged dev
/// build with no dev account configured keeps its own store and starts signed out, even while NIGHTLY is signed in:
/// it signs in itself, once per build, in the browser.
@MainActor @Suite struct CloudAuthNeverNightlySessionTests {
    /// A signed-in cmux NIGHTLY; counts every time a dev build asks it for its session.
    actor SignedInNightly {
        var reads = 0
        func handOff() -> (accessToken: String?, refreshToken: String)? {
            reads += 1
            return ("access-nightly", "refresh-nightly")
        }
    }

    /// A tagged dev build (`dev:next`) on the production account, NIGHTLY's.
    static func taggedDevBuildOnProduction() -> CloudConfiguration {
        var configuration = CloudConfiguration.unavailable
        configuration.isProductionAuth = true
        configuration.buildSpace = CMUXBuildSpaceState(devBuild: true, devTag: "next")
        return configuration
    }

    @Test func aTaggedDevBuildWithNoDevAccountStaysSignedOutWhileNightlyIsSignedIn() async throws {
        let configuration = Self.taggedDevBuildOnProduction()
        // No dev account: no launch keys and a home without ~/.config/cmux/dev-account or ~/.secrets/cmuxterm-dev.env.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("no-dev-account-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let nightly = SignedInNightly()
        let devAccount = CloudAuth.launchDevAccount(configuration: configuration, environment: [:], home: home.path)
        let store = CloudAuth.tokenStore(configuration: configuration, nightlySession: { await nightly.handOff() },
                                         devAccount: devAccount)
        // The build's own Keychain store with its file fallback, never a memory store filled from NIGHTLY.
        #expect(store is FallbackTokenStore)
        #expect(!(store is ImportingTokenStore))
        #expect(!(store is MemoryStackTokenStore))
        if let importing = store as? ImportingTokenStore {
            #expect(await importing.getStoredRefreshToken() != "refresh-nightly")
            #expect(await importing.getStoredAccessToken() != "access-nightly")
        }
        #expect(await nightly.reads == 0)
    }
}
