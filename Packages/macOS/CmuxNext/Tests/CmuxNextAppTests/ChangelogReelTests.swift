@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextUpdater
import Foundation
import Testing

/// What's New shows a build's nightly reel (whats-new lane, 2026-10-20): the nightly publishes
/// `nightly-next/<build>/reel.json` and `reel.mp4` on the pr-media branch
/// (scripts/cmux-next/media/reel.py), and `cmux.changelog.get` names the reel only when its
/// `reel.json` says one was built, so the page never links a missing video.
@MainActor @Suite(.serialized) struct ChangelogReelTests {
    typealias Load = ChangelogNotesLoadTests

    /// `cmux.changelog.get`'s `reel` for the build when the network serves `reelJSON` as its reel.json.
    func reel(_ reelJSON: String?) async throws -> JSONValue? {
        let fixture = Load.Fixture()
        defer { fixture.tearDown() }
        var files = try fixture.served("A nightly with a reel")
        if let reelJSON { files["reel.json"] = Data(reelJSON.utf8) }
        let network = Load.Network(files: files)
        let store = try #require(ReleaseNotesStore(feedURL: "https://notes.test/nightly-next/appcast.xml", cache: fixture.cache,
                                                   publicKey: fixture.publicKey, fetcher: network))
        let media = ReleaseMediaStore(cache: fixture.cache.appending(path: "media"), bundledDirectories: [], fetcher: network,
                                      siteBase: nil)
        let page = ChangelogPageProvider(source: store, currentBuild: Load.build, media: media)
        let result = try await page.call("cmux.changelog.get", params: ["build": .string(Load.build)], context: Load.context)
        #expect(result["changes"]?.arrayValue?.first?.stringValue == "A nightly with a reel")
        return result["reel"]
    }

    @Test func aBuildWithAReelLinksItsVideo() async throws {
        let reel = try await reel(#"{"build": "4242", "reel": "reel.mp4", "prs": []}"#)
        #expect(reel?.stringValue == "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/nightly-next/4242/reel.mp4")
    }

    @Test func aBuildWithoutAReelLinksNone() async throws {
        // reel.py writes "reel": null when no pull request in the build has a clip.
        #expect(try await reel(#"{"build": "4242", "reel": null, "prs": []}"#) == nil)
        // No reel.json at all (the reel job failed or has not run), or one that is not JSON.
        #expect(try await reel(nil) == nil)
        #expect(try await reel("<html>") == nil)
    }
}
