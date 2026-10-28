import AppKit
import CmuxNextCloud
import CmuxNextCodeRouter
@testable import CmuxNextApp
import Testing

/// The named auth capture profile keeps the real CloudAuth and Accounts routes
/// visible while replacing every credential and provider probe with isolated,
/// offline dependencies.
@MainActor @Suite(.serialized)
struct AuthCaptureFixtureTests {
    @Test func theNamedProfileIsDebugOnly() {
        let environment = AppEnvironment.current(["CMUX_NEXT_AUTH_CAPTURE_FIXTURE": "1"])
#if DEBUG
        #expect(environment.authCaptureFixture)
#else
        #expect(!environment.authCaptureFixture)
#endif
    }

    @Test func accountsFixtureReadsNoAmbientProviderInputs() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_AUTH_CAPTURE_FIXTURE": "1"]))
        let environment = await services.accounts.detectionEnvironment()

        #expect(environment.environment.isEmpty)
        #expect(environment.home.path.contains("cmux-auth-capture/providers"))
        #expect(!environment.keychain.hasGenericPassword(service: "com.example.ambient"))
        let server = try #require(URL(string: "http://127.0.0.1:11434"))
        #expect(await !environment.servers.isReachable(server))
        #expect(environment.files.data(at: URL(fileURLWithPath: "/etc/passwd")) == nil)
        #expect(!environment.files.exists(URL(fileURLWithPath: "/etc/passwd")))
        try services.accounts.keys.save("capture-only", for: .codex)
        #expect(try services.accounts.keys.key(for: .codex) == "capture-only")
        try services.accounts.keys.delete(for: .codex)
        #expect(services.accounts.keys.savedProviders().isEmpty)
    }

    @Test func cloudAuthFixtureUsesTheRealCoordinatorWithoutStoredCredentials() async {
        let configuration = CloudConfiguration.resolve(bundleID: "com.cmuxterm.capture", bundled: [:],
                                                        process: [:], isDebugBuild: true)
        let auth = CloudAuth(configuration: configuration, environment: [:], captureFixture: true)
        auth.start()
        await auth.awaitRestored()

        #expect(!auth.isSignedIn)
        #expect(auth.user == nil)
        await #expect(throws: Error.self) { try await auth.tokens() }
        #expect(await !auth.browserSignIn.beginSignIn(inDefaultBrowser: true).value)
        #expect(await !auth.browserSignIn.beginSignIn(inDefaultBrowser: false).value)
        #expect(!auth.continueSignInInBrowser())
        #expect(!auth.isSignedIn)
    }
}
