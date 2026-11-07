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

    /// Leo, 2026-11-04: "when we launch dev builds, we wanted to be able to have all the stuff with auth included
    /// already". The signed NEXT DEV build (a Release compile on the development Stack project) signs in from the
    /// credentials file its launch names, keeps a session already signed in, and gets no debug sign-in surface.
    @Test func signedNextDEVSignsInFromItsLaunchCredentialsFile() {
        let dev = resolve("com.cmuxterm.app.debug.next", debug: false)
        #expect(!dev.isProductionAuth)
        #expect(CloudAuth.launchSignIn(configuration: dev, environment: file)
            == .init(devAuth: false, autoLogin: true, replacesSession: false))
        // Without the file it never reads the ambient secrets files.
        #expect(CloudAuth.launchSignIn(configuration: dev, environment: [:])
            == .init(devAuth: false, autoLogin: false, replacesSession: false))
        // An explicit replace still replaces.
        #expect(CloudAuth.launchSignIn(configuration: dev, environment: file.merging(["CMUX_DEV_AUTH_REPLACE_SESSION": "1"]) { $1 })
            == .init(devAuth: false, autoLogin: true, replacesSession: true))
    }

    /// Shipped builds other than cmux NIGHTLY never sign in from the launch, and NIGHTLY only from an explicit file.
    @Test func shippedBuildsNeverSignInFromTheLaunch() {
        for bundleID in [nil, "com.cmuxterm.app", "com.cmuxterm.app.nightly.cmux-next", "com.cmuxterm.app.rc"] {
            let config = resolve(bundleID, debug: false)
            #expect(config.isProductionAuth)
            #expect(CloudAuth.launchSignIn(configuration: config, environment: file)
                == .init(devAuth: false, autoLogin: false, replacesSession: false), "\(bundleID ?? "nil")")
        }
        let nightly = resolve("com.cmuxterm.app.nightly", debug: false)
        #expect(CloudAuth.launchSignIn(configuration: nightly, environment: [:])
            == .init(devAuth: false, autoLogin: false, replacesSession: false))
        #expect(CloudAuth.launchSignIn(configuration: nightly, environment: ["CMUX_AUTH_CREDENTIALS_FILE": ""])
            == .init(devAuth: false, autoLogin: false, replacesSession: false))
    }

    /// Leo, 2026-11-05: "Just add the credentials in. Stop blocking. ... Just make it safe." Signed cmux NIGHTLY
    /// signs in from the explicit file its launch names, so an end-to-end check runs headless on a CI Mac. That
    /// session lives in memory only and never replaces the one in its Keychain; no debug sign-in surface.
    @Test func signedNightlySignsInFromAnExplicitFileInMemoryOnly() {
        let nightly = resolve("com.cmuxterm.app.nightly", debug: false)
        #expect(nightly.isProductionAuth)
        #expect(CloudAuth.launchSignIn(configuration: nightly, environment: file)
            == .init(devAuth: false, autoLogin: true, replacesSession: false, memoryOnly: true))
        // A replace request changes nothing: there is no stored session to replace in memory.
        #expect(CloudAuth.launchSignIn(configuration: nightly, environment: file.merging(["CMUX_DEV_AUTH_REPLACE_SESSION": "1"]) { $1 })
            == .init(devAuth: false, autoLogin: true, replacesSession: false, memoryOnly: true))
        #expect(CloudAuth.tokenStore(configuration: nightly, nightlySession: nil, memoryOnly: true) is MemoryStackTokenStore)
        #expect(!(CloudAuth.tokenStore(configuration: nightly, nightlySession: nil) is MemoryStackTokenStore))
    }

    @Test func debugBuildsKeepTheirDevAuth() {
        let staging = resolve("com.cmuxterm.app.debug.mytag", debug: true)
        #expect(CloudAuth.launchSignIn(configuration: staging, environment: [:])
            == .init(devAuth: true, autoLogin: true, replacesSession: false))
        #expect(CloudAuth.launchSignIn(configuration: staging, environment: file)
            == .init(devAuth: true, autoLogin: true, replacesSession: true))
        let production = resolve("com.cmuxterm.app.debug.mytag", debug: true, backend: "prod")
        #expect(CloudAuth.launchSignIn(configuration: production, environment: [:])
            == .init(devAuth: false, autoLogin: false, replacesSession: false))
        #expect(CloudAuth.launchSignIn(configuration: production, environment: file)
            == .init(devAuth: true, autoLogin: true, replacesSession: true))
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
