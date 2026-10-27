@testable import CmuxNextUpdater
import Foundation
import Testing

/// Which bundles take web updates (plans/cmux-next/web-ota.md): NIGHTLY and the tip app, which both
/// follow feat-cmux-next; no other DEV, Debug, Release or RC build.
struct WebUpdatesAvailabilityTests {
    static func identity(_ bundleIdentifier: String?, feed: String? = nil) -> UpdateBuildIdentity {
        var info: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]
        if let bundleIdentifier { info["CFBundleIdentifier"] = bundleIdentifier }
        if let feed { info["SUFeedURL"] = feed }
        return UpdateBuildIdentity(infoDictionary: info)
    }

    @Test func nightlyBundlesTakeWebUpdates() {
        #expect(WebUpdater.takesUpdates(Self.identity("com.cmuxterm.app.nightly")))
        #expect(WebUpdater.takesUpdates(Self.identity("com.cmuxterm.app.nightly.leo")))
        #expect(!WebUpdater.takesUpdates(Self.identity("com.cmuxterm.app.nightlyx")))
    }

    @Test func theTipAppTakesWebUpdates() {
        let tipFeed = UpdateBuildIdentity.tipFeedPrefix + "appcast-arm64.xml"
        #expect(WebUpdater.takesUpdates(Self.identity(UpdateBuildIdentity.tipBundleIdentifier, feed: tipFeed)))
        // The same id without the tip feed is a developer's own `reload.sh --tag next` build.
        #expect(!WebUpdater.takesUpdates(Self.identity(UpdateBuildIdentity.tipBundleIdentifier)))
        #expect(!WebUpdater.takesUpdates(Self.identity(UpdateBuildIdentity.tipBundleIdentifier,
                                                       feed: "https://files.cmux.com/nightly-next/appcast-arm64.xml")))
        // The tip feed in another bundle is not the tip app.
        #expect(!WebUpdater.takesUpdates(Self.identity("com.cmuxterm.app.debug", feed: tipFeed)))
    }

    @Test func releaseRcDebugAndUnknownBundlesKeepTheirWeb() {
        for id in ["com.cmuxterm.app", "com.cmuxterm.app.rc", "com.cmuxterm.app.debug", "com.cmuxterm.app.debug.next.other"] {
            #expect(!WebUpdater.takesUpdates(Self.identity(id)), "\(id)")
        }
        #expect(!WebUpdater.takesUpdates(Self.identity(nil)))
    }
}
