import CmuxNextCloud
import Foundation
import Testing

/// A guest link's owner token comes from the API of the room the daemon makes the link in
/// (cmux-tui share_room.rs): a DEV build's room is development's, while it signs in to staging's Worker.
@Suite
struct CloudShareAPITests {
    @Test func aDebugBuildMintsShareTokensFromTheDevelopmentWorker() {
        let configuration = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.walk", bundled: [:], process: [:], isDebugBuild: true)
        #expect(configuration.ownerAPIBaseURL(environment: [:]).absoluteString == "https://cloud-api-staging.cmux.dev")
        #expect(configuration.shareAPIBaseURL(environment: [:]).absoluteString == "https://cmux-api-development.debussy.workers.dev")
    }

    @Test func anOwnerAPIOverrideIsTheShareAPITooAndAReleaseBuildKeepsItsOwnerAPI() {
        let debug = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.walk", bundled: [:], process: [:], isDebugBuild: true)
        let named = ["CMUX_NEXT_FEED_API_URL": "https://owner.standin.invalid"]
        #expect(debug.shareAPIBaseURL(environment: named) == debug.ownerAPIBaseURL(environment: named))
        let release = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app", bundled: [:], process: [:], isDebugBuild: false)
        #expect(release.shareAPIBaseURL(environment: [:]) == release.ownerAPIBaseURL(environment: [:]))
    }
}
