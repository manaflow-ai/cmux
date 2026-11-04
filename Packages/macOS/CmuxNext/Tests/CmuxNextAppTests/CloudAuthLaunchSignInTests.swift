import Foundation
import Testing
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

    @Test func shippedBuildsNeverSignInFromTheLaunch() {
        for bundleID in [nil, "com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc"] {
            let config = resolve(bundleID, debug: false)
            #expect(config.isProductionAuth)
            #expect(CloudAuth.launchSignIn(configuration: config, environment: file)
                == .init(devAuth: false, autoLogin: false, replacesSession: false), "\(bundleID ?? "nil")")
        }
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
}
