import AppKit
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextLaunch
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Cloud and the feed on demand (p08-startup task 020): `AppServices.init` and the launch readers build
/// neither; a Cloud machine's window starts Cloud right after the first frame; a token reader or a
/// sign-in starts the session restore first.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CloudOnDemandTests {
    @Test func servicesInitAndTheLaunchReadersBuildNeitherCloudNorTheFeed() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.cloudIfBuilt == nil, "init builds no CloudService (the hands' banners wait for the Cloud start)")
        #expect(services.feedIfBuilt == nil, "init builds no feed")
        #expect(services.cloudContext == nil, "Cloud starts from the launch's post, not from init")
        #expect(services.notifications.feedDriver == nil, "the feed handoff waits for the Cloud start")
        // The launch's policy enforcer and the feed.github setting keep their values for the builds.
        services.applyCloudPolicy(disabled: true)
        services.configureFeedGitHub(enabled: false, pollIntervalSeconds: 300)
        services.cloudContextDidChange()
        services.stopCloud()
        #expect(services.cloudIfBuilt == nil && services.feedIfBuilt == nil && services.cloudContext == nil)
        #expect(services.cloud.policyDisabled, "the policy applies when CloudService is built")
    }

    /// The restore makes its saved windows after the first frame: a Cloud machine's window made then
    /// starts Cloud in the next frame, not at the end of startup that window holds open.
    @Test func aCloudWindowMadeAfterTheFirstFrameStartsCloudInTheNextFrame() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let s = StartupTestScheduler(), starts = StartCount()
        let post = CloudStartPost(startup: s.startup, start: { starts.count += 1 })
        services.cloudStart = post
        post.post()
        let local = services.windows.makeController(for: WindowRegistry.Window(id: "local-window"))
        s.startup.firstFrameCommitted()
        s.fire()
        #expect(starts.count == 0, "a local window needs no Cloud")
        services.windows.states["cloud-window"] = WindowState(id: "cloud-window", machineID: "vm-on-demand")
        let remote = services.windows.makeController(for: WindowRegistry.Window(id: "cloud-window"))
        s.fire()
        #expect(starts.count == 1, "the Cloud machine's window starts Cloud in the next frame")
        #expect(s.startup.completion == nil, "before startup completes")
        for controller in [local, remote] {
            controller.teardown()
            controller.window?.close()
        }
    }

    @Test func aTokenReaderBeforeTheCloudStartWaitsForTheRestore() async throws {
        let (auth, defaults, id) = try Self.primedAuth()
        defer { defaults.removePersistentDomain(forName: id) }
        #expect(auth.isRestoring, "a stored session primes as restoring")
        await auth.awaitRestored()
        #expect(!auth.isRestoring, "the reader started the restore and waited for it")
    }

    @Test func aSignInCallbackStartsCloudAndTheRestoreBeforeTheFlow() async throws {
        let (auth, defaults, id) = try Self.primedAuth()
        defer { defaults.removePersistentDomain(forName: id) }
        let starts = StartCount()
        auth.onSignIn = { starts.count += 1 }
        _ = await auth.handleCallback(auth.configuration.callbackURL)
        #expect(starts.count == 1, "the callback started Cloud (AppServices.startCloudNow)")
        await auth.coordinator.awaitBootstrapped()  // does not start a restore: returns at once when none started
        #expect(!auth.isRestoring, "the callback started the restore")
    }

    /// A CloudAuth of its own keychain service and defaults, primed with a stored session (no tokens).
    private static func primedAuth() throws -> (CloudAuth, UserDefaults, String) {
        let id = "test.cloud-on-demand.\(UUID().uuidString.lowercased())"
        let defaults = try #require(UserDefaults(suiteName: id))
        defaults.set(true, forKey: "cmux.auth.hasTokens")
        let configuration = CloudConfiguration.resolve(bundleID: id, bundled: [:], process: [:], isDebugBuild: false)
        return (CloudAuth(configuration: configuration, environment: [:], defaults: defaults, openExternalURL: { _ in }), defaults, id)
    }
}

@MainActor
private final class StartCount {
    var count = 0
}
