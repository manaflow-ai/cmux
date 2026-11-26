@testable import CmuxNextControl
import Testing

/// Another cmux's terminals export that app's Cloud selection (`CMUX_NEXT_CLOUD_RUNTIME`, `_ENV`, `_BACKEND`;
/// AppDelegate after its Cloud bootstrap). Before: the launch strip kept every `CMUX_NEXT_*` knob, so a tagged
/// DEV build opened from a cmux NIGHTLY terminal handed the nightly's `prod` to `cloud env get` as its launch
/// seed, took production instead of its own `dev`, and came up signed out.
@Suite struct LaunchIdentityCloudSelectionTests {
    static let devBundle = "com.cmuxterm.app.debug.dev-env-isolation"
    /// What a cmux NIGHTLY terminal exports (its identity and its Cloud selection).
    static let nightlyTerminal = [
        "CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly",
        "CMUX_SOCKET_PATH": "/Users/me/.local/state/cmux/cmux-nightly.sock",
        "CMUX_NEXT_CLOUD_RUNTIME": "1",
        "CMUX_NEXT_CLOUD_ENV": "prod",
        "CMUX_NEXT_CLOUD_BACKEND": "https://cloud-api.cmux.dev",
        "CMUX_PLATFORM_ORIGIN": "https://cmux-platform-production.example",
    ]
    static let cloudKeys: Set = ["CMUX_NEXT_CLOUD_RUNTIME", "CMUX_NEXT_CLOUD_ENV", "CMUX_NEXT_CLOUD_BACKEND"]

    @Test func anotherCmuxsCloudSelectionIsNotThisAppsLaunchSeed() {
        let stripped = Set(LaunchIdentity.inheritedKeys(processEnvironment: Self.nightlyTerminal, bundledEnvironment: [:]))
        #expect(stripped.isSuperset(of: Self.cloudKeys))
        #expect(stripped.contains("CMUX_PLATFORM_ORIGIN"))
    }

    /// Only the foreign `CMUX_BUNDLE_ID` marks the launch as another cmux's: still not this app's selection.
    @Test func aForeignBundleIDAloneStillDropsTheCloudSelection() {
        let environment = ["CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly", "CMUX_NEXT_CLOUD_BACKEND": "prod"]
        #expect(Set(LaunchIdentity.inheritedKeys(processEnvironment: environment, bundledEnvironment: [:]))
            == ["CMUX_BUNDLE_ID", "CMUX_NEXT_CLOUD_BACKEND"])
    }

    /// A launch from outside any cmux (a script, `open --env`) keeps its deliberate backend.
    @Test func aDeliberateBackendOutsideAnyCmuxSurvivesTheStrip() {
        for key in Self.cloudKeys {
            #expect(LaunchIdentity.inheritedKeys(processEnvironment: [key: "staging"], bundledEnvironment: [:]).isEmpty)
        }
    }

    /// A backend the bundle's own `LSEnvironment` names is the app's own, inside another cmux too.
    @Test func theBundlesOwnBackendSurvivesInsideAnotherCmux() {
        let bundled = ["CMUX_NEXT_CLOUD_BACKEND": "staging"]
        let environment = Self.nightlyTerminal.merging(bundled) { $1 }
        #expect(!LaunchIdentity.inheritedKeys(processEnvironment: environment, bundledEnvironment: bundled)
            .contains("CMUX_NEXT_CLOUD_BACKEND"))
    }

    /// A launcher inside another cmux that names this app (`CMUX_BUNDLE_ID` set to its bundle id) sets the
    /// backend for this app on purpose; its other cmux markers are still dropped.
    @Test func aLauncherThatNamesThisAppKeepsItsBackend() {
        let environment = Self.nightlyTerminal.merging(["CMUX_BUNDLE_ID": Self.devBundle,
                                                        "CMUX_NEXT_CLOUD_BACKEND": "staging"]) { $1 }
        let stripped = Set(LaunchIdentity.inheritedKeys(processEnvironment: environment, bundledEnvironment: [:],
                                                        bundleID: Self.devBundle))
        #expect(stripped.isDisjoint(with: Self.cloudKeys))
        #expect(stripped.isSuperset(of: ["CMUX_BUNDLE_ID", "CMUX_SOCKET_PATH"]))
        // The nightly's own bundle id names the nightly, not this DEV build.
        #expect(Set(LaunchIdentity.inheritedKeys(processEnvironment: Self.nightlyTerminal, bundledEnvironment: [:],
                                                 bundleID: Self.devBundle)).isSuperset(of: Self.cloudKeys))
    }
}
