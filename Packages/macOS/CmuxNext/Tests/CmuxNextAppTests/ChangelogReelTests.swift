@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import CmuxNextUpdater
import Foundation
import Testing

/// What's New shows a build's nightly reel (whats-new lane, 2026-10-20): the nightly publishes
/// `nightly-next/<build>/reel.json` and `reel.mp4` on the pr-media branch
/// (scripts/cmux-next/media/reel.py), and `cmux.changelog.reel` names the reel only when its
/// `reel.json` says one was built, so the page never links a missing video. `cmux.changelog.get`
/// never waits for it: the notes and their media come from the cache with no network at all.
@MainActor @Suite(.serialized) struct ChangelogReelTests {
    typealias Load = ChangelogNotesLoadTests

    /// A network that never answers for reel.json (a captive portal, a stalled connection).
    actor StalledReel: AppcastFetching {
        let files: [String: Data]
        init(files: [String: Data]) { self.files = files }

        func fetch(_ url: URL) async throws -> Data {
            if url.lastPathComponent == "reel.json" { try await Task.sleep(for: .seconds(30)) }
            guard let data = files[url.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
            return data
        }
    }

    static func page(_ fixture: Load.Fixture, _ network: any AppcastFetching) throws -> ChangelogPageProvider {
        let store = try #require(ReleaseNotesStore(feedURL: "https://notes.test/nightly-next/appcast.xml", cache: fixture.cache,
                                                   publicKey: fixture.publicKey, fetcher: network))
        let media = ReleaseMediaStore(cache: fixture.cache.appending(path: "media"), bundledDirectories: [], fetcher: network,
                                      siteBase: nil)
        return ChangelogPageProvider(source: store, currentBuild: Load.build, media: media)
    }

    /// `cmux.changelog.reel`'s `url` for the build when the network serves `reelJSON` as its reel.json.
    func reel(_ reelJSON: String?) async throws -> JSONValue? {
        let fixture = Load.Fixture()
        defer { fixture.tearDown() }
        var files = try fixture.served("A nightly with a reel")
        if let reelJSON { files["reel.json"] = Data(reelJSON.utf8) }
        let result = try await Self.page(fixture, Load.Network(files: files))
            .call("cmux.changelog.reel", params: ["build": .string(Load.build)], context: Load.context)
        guard let url = result["url"], case .string = url else { return nil }
        return url
    }

    @Test func theNotesNeverWaitForTheReel() async throws {
        let fixture = Load.Fixture()
        defer { fixture.tearDown() }
        let page = try Self.page(fixture, StalledReel(files: try fixture.served("A nightly with a reel")))
        let started = ContinuousClock.now
        let result = try await page.call("cmux.changelog.get", params: ["build": .string(Load.build)], context: Load.context)
        #expect(result["changes"]?.arrayValue?.first?.stringValue == "A nightly with a reel")
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// The page plays the reel inline (Leo 2026-10-21: one reel at the top of What's New), so its
    /// policy admits the folder the store names reels in, and only that folder.
    @Test func thePagePolicyAdmitsTheReelFolder() throws {
        let store = ReleaseMediaStore(cache: FileManager.default.temporaryDirectory, bundledDirectories: [])
        let base = try #require(store.reelBase)
        #expect(PageDescriptor.changelog.csp.media == ["data:", base.absoluteString])
        #expect(PageDescriptor.changelog.csp.header.contains("media-src data: \(base.absoluteString)"))
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
