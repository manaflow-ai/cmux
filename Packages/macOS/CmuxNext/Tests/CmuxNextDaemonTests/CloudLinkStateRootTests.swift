import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The Cloud server learns of this Mac's `cmux link` only through `link.json`
/// in the app daemon's state directory, so the link must run in that same
/// directory. The untagged NIGHTLY (`com.cmuxterm.app.nightly`) keeps its
/// names and runs its daemon in `tags/nightly/tui`; its link used cmux-tui's
/// default root instead, and every Cloud chat failed with "The Cloud
/// connection helper is not running on this Mac" while the link ran.
struct CloudLinkStateRootTests {
    private func appSupport() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cloud-link-root-\(UUID().uuidString)", isDirectory: true)
    }

    @Test(arguments: [
        ("com.cmuxterm.app.nightly", nil as String?),
        ("com.cmuxterm.app.rc", nil),
        ("com.cmuxterm.app.staging", nil),
        ("com.cmuxterm.app.nightly.cmux-next", nil),
        ("com.cmuxterm.app.debug", "my-tag"),
        ("com.cmuxterm.app.debug", nil),
    ])
    func theLinkRunsInTheDaemonsStateDirectory(bundleID: String, tag: String?) throws {
        let support = appSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let build = BuildIdentity(bundleID: bundleID, bundledTag: tag)
        let daemon = try #require(DaemonLauncher.appNames(build: build, applicationSupport: support).stateDirectory)
        let link = try #require(CloudLinkLauncher.linkStateRoot(build: build, applicationSupport: support))
        #expect(link.root.standardizedFileURL == daemon.standardizedFileURL)
        #expect(link.own)
    }

    @Test func theUntaggedNightlysLinkIsInTagsNightly() throws {
        let support = appSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let build = BuildIdentity(bundleID: "com.cmuxterm.app.nightly", bundledTag: nil)
        let link = try #require(CloudLinkLauncher.linkStateRoot(build: build, applicationSupport: support))
        #expect(link.root.standardizedFileURL.path
            == support.appendingPathComponent("cmux/tags/nightly/tui").standardizedFileURL.path)
    }

    @Test func releaseUsesTheDefaultRootAndTheSharedPort() throws {
        let support = appSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let build = BuildIdentity(bundleID: "com.cmuxterm.app", bundledTag: nil)
        #expect(DaemonLauncher.appNames(build: build, applicationSupport: support).stateDirectory == nil)
        let link = try #require(CloudLinkLauncher.linkStateRoot(build: build, applicationSupport: support))
        #expect(link.root == CloudLinkLauncher.defaultStateRoot())
        #expect(!link.own)
    }
}
