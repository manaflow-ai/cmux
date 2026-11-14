import Foundation
import Testing
import CmuxAuthRuntime
@testable import CmuxNextCloud

/// ``CloudAuth/launchSignIn(configuration:environment:)``: which launches sign in from the credentials they were given.
struct CloudAuthLaunchSignInTests {
    private let file = ["CMUX_AUTH_CREDENTIALS_FILE": "/Users/me/.secrets/cmuxterm-dev.env"]

    private func resolve(_ bundleID: String?, debug: Bool, backend: String? = nil) -> CloudConfiguration {
        var configuration = CloudConfiguration.resolve(bundleID: bundleID, bundled: [:], process: [:], isDebugBuild: debug)
        if let backend, var selection = configuration.runtimeSelection {
            selection.name = backend
            configuration = CloudConfiguration.from(selection: selection, bundleID: bundleID, bundled: [:], process: [:], isDebugBuild: debug)
        }
        return configuration
    }

    /// The launch rules are Rust's (cmux-cloud-config `auth::launch_sign_in`, with their cases); this checks the
    /// app gets their answer, and that a memory-only launch keeps its session out of the Keychain.
    @Test func signedNightlySignsInFromAnExplicitFileInMemoryOnly() {
        let nightly = resolve("com.cmuxterm.app.nightly", debug: false)
        #expect(nightly.isProductionAuth)
        #expect(CloudAuth.launchSignIn(configuration: nightly, environment: file).signIn
            == .init(devAuth: false, autoLogin: true, replacesSession: false, memoryOnly: true))
        #expect(CloudAuth.launchSignIn(configuration: nightly, environment: [:]).signIn == .noSignIn)
        #expect(CloudAuth.tokenStore(configuration: nightly, nightlySession: nil, memoryOnly: true) is MemoryStackTokenStore)
        #expect(!(CloudAuth.tokenStore(configuration: nightly, nightlySession: nil) is MemoryStackTokenStore))
    }

    /// A debug build reads the ambient account files; a signed build only the explicit one.
    @Test func theFilesReadFollowTheLaunch() {
        let staging = resolve("com.cmuxterm.app.debug.mytag", debug: true)
        let ambient = CloudAuth.launchSignIn(configuration: staging, environment: [:], home: "/h")
        #expect(ambient.signIn == .init(devAuth: true, autoLogin: true, replacesSession: false))
        #expect(ambient.paths == ["/h/.config/cmux/dev-account", "/h/.secrets/cmuxterm-dev.env", "/h/.secrets/cmux.env"])
        let dev = resolve("com.cmuxterm.app.debug.next", debug: false)
        #expect(CloudAuth.launchSignIn(configuration: dev, environment: file, home: "/h").paths == [file["CMUX_AUTH_CREDENTIALS_FILE"]])
        // A file that is not this user's 0600 regular file is never read for its account.
        let login = CloudAuth.launchLogin(.init(devAuth: false, autoLogin: true, replacesSession: false),
                                          paths: ["/dev/null"], environment: ["CMUX_AUTH_CREDENTIALS_FILE": "/dev/null"], home: "/h")
        #expect(login?.credentials == nil)
        #expect(login?.allowsEnvironmentAutoLogin == false)
    }

    /// The memory-only caches keep what was set for the life of the process, and never touch the app's defaults.
    @Test func memoryOnlyCachesRoundTrip() {
        let store = MemoryAuthKeyValueStore()
        store.set(true, forKey: "flag")
        store.set(Data([1, 2]), forKey: "data")
        store.set("text", forKey: "text")
        #expect(store.bool(forKey: "flag"))
        #expect(store.data(forKey: "data") == Data([1, 2]))
        #expect(store.string(forKey: "text") == "text")
        #expect(store.string(forKey: "flag") == nil)
        store.removeObject(forKey: "text")
        #expect(store.string(forKey: "text") == nil)
        #expect(UserDefaults.standard.object(forKey: "flag") == nil)
    }
}
