@testable import CmuxNextUpdater
import CmuxUpdater
import Foundation
import Testing

/// A test update feed changes where a NIGHTLY build installs updates from, so
/// only the person may turn one on there: a request over the socket asks them
/// first. DEV builds never install (Sparkle is off), so they apply it at once.
/// Returning to the real feed never asks.
struct TestFeedConsentTests {
    @Test func aNightlyTestFeedAsksThePersonFirst() {
        #expect(UpdaterService.testFeedRequest(url: "https://example.com/appcast.xml", track: .nightly) == .askFirst)
    }

    @Test func aDevTestFeedApplies() {
        #expect(UpdaterService.testFeedRequest(url: "https://example.com/appcast.xml", track: .development) == .apply)
    }

    @Test func returningToTheRealFeedNeverAsks() {
        #expect(UpdaterService.testFeedRequest(url: nil, track: .nightly) == .apply)
    }

    @Test func stableAndRCRefuse() {
        #expect(UpdaterService.testFeedRequest(url: "https://example.com/appcast.xml", track: .stable) == .refuse)
        #expect(UpdaterService.testFeedRequest(url: "https://example.com/appcast.xml", track: .rc) == .refuse)
    }

    @Test func aFeedThatIsNotHTTPSOrLoopbackRefuses() {
        #expect(UpdaterService.testFeedRequest(url: "http://example.com/appcast.xml", track: .nightly) == .refuse)
        #expect(UpdaterService.testFeedRequest(url: "file:///tmp/appcast.xml", track: .development) == .refuse)
    }

    /// Sparkle offers only a build newer than the running one (its standard
    /// comparator, no `bestValidUpdateInAppcast` override in the seam), so a
    /// test feed cannot install an older or the same build.
    @Test func sparkleOrdersTheRunningBuildAsNotNewer() {
        let comparator = SparkleVersionComparator()
        #expect(comparator.compare("100", "100") == .orderedSame)
        #expect(comparator.compare("99", "100") == .orderedAscending)
    }

    /// A pin another process wrote into the app's defaults (any process of
    /// this user can) never applies by itself at a NIGHTLY launch: the
    /// person is asked again first.
    @Test func aNightlyPinNeedsTheQuestionAgainAtLaunch() {
        #expect(UpdaterService.pinnedTestFeedAtLaunch(track: .nightly) == .askFirst)
        #expect(UpdaterService.pinnedTestFeedAtLaunch(track: .development) == .apply)
        #expect(UpdaterService.pinnedTestFeedAtLaunch(track: .stable) == .refuse)
    }
}
