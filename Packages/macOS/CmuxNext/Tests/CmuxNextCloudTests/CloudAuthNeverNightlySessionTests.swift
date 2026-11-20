import CMUXAuthCore
import CmuxAuthRuntime
@testable import CmuxNextCloud
import Foundation
import Testing

/// Regression (2026-11-18): no dev build takes cmux NIGHTLY's signed-in session. The production cloud-api ignores
/// `X-Cmux-Build-Space`, so a dev build on NIGHTLY's session would read and write NIGHTLY's real data. A tagged dev
/// build with no dev account configured keeps its own store and starts signed out, even while NIGHTLY is signed in:
/// it signs in itself, once per build, in the browser.
///
/// The tests-first commit ran this with a signed-in NIGHTLY handing its session over (`auth.session.handoff`), and
/// it failed: that build adopted NIGHTLY's session into a memory store. That source no longer exists, so a dev
/// build's launch store is its own: an adoption brought back in any shape (a memory store, or an importing store
/// fed from NIGHTLY) fails here.
@MainActor @Suite struct CloudAuthNeverNightlySessionTests {
    /// A tagged dev build (`dev:next`) on the production account, NIGHTLY's.
    static func taggedDevBuildOnProduction() -> CloudConfiguration {
        var configuration = CloudConfiguration.unavailable
        configuration.isProductionAuth = true
        configuration.buildSpace = CMUXBuildSpaceState(devBuild: true, devTag: "next")
        return configuration
    }

    @Test func aTaggedDevBuildWithNoDevAccountStaysSignedOutWhileNightlyIsSignedIn() async throws {
        let configuration = Self.taggedDevBuildOnProduction()
        // No dev account: the launch signs nothing in, so the store is the one CloudAuth.init builds for it.
        let store = CloudAuth.tokenStore(configuration: configuration)
        // The build's own Keychain store with its file fallback, never a memory store filled from NIGHTLY.
        #expect(store is FallbackTokenStore)
        #expect(!(store is ImportingTokenStore))
        #expect(!(store is MemoryStackTokenStore))
    }
}
