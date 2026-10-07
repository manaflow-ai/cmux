import Foundation
import Testing
@testable import CmuxNextUpdater

/// WHATS-NEW-AFTER-UPDATE W2: the app reads the same documents the release
/// gate validates, orders versions, picks the reader's language, and drops
/// what it must not show instead of failing.
@Suite struct WhatsNewDocumentTests {
    @Test func theValidatorsGoodFixtureDecodes() throws {
        let data = try Data(contentsOf: WhatsNewFixtures.sharedFixtureURL)
        let document = try #require(WhatsNewDocument.decode(data, origin: .bundled))
        #expect(document.version == "1.0.0-nightly.42")
        #expect(document.channel == .nightly)
        #expect(document.entries.map(\.id) == ["whats-new-page", "sidebar-scroll"])
        #expect(document.entries[0].tryIt?.action == "updates.whatsNew")
        #expect(document.entries[1].docs?.absoluteString == "https://cmux.com/docs/sidebar")
    }

    @Test func versionsOrderNumericallyWithPrereleasesBeforeTheirRelease() throws {
        let ordered = ["0.9.0", "0.10.0-nightly.3", "0.10.0-nightly.12", "0.10.0-rc.13", "0.10.0", "1.0.0-nightly.3720357958801", "1.0.0"]
        let versions = try ordered.map { try #require(WhatsNewVersion($0)) }
        #expect(versions == versions.sorted())
        #expect(versions.map(\.description) == ordered)
        for bad in ["1.0", "1.0.0-beta.1", "v1.0.0", "1.0.0-nightly", "1.0.0-rc.x", ""] {
            #expect(WhatsNewVersion(bad) == nil, "\(bad)")
        }
    }

    @Test func textPicksThePreferredLanguageThenItsBaseThenEnglish() {
        let text = WhatsNewText(["en": "New", "ja": "新機能", "zh-Hant": "新功能（繁）", "pt-BR": "Novo", "nb": "Nytt"])
        #expect(text.resolved(for: ["ja-JP"]) == "新機能")
        #expect(text.resolved(for: ["zh-Hant-TW"]) == "新功能（繁）")
        #expect(text.resolved(for: ["pt-PT"]) == "Novo")
        #expect(text.resolved(for: ["no"]) == "Nytt")
        #expect(text.resolved(for: ["de-DE", "ja"]) == "新機能")
        #expect(text.resolved(for: ["fr"]) == "New")
    }

    @Test func entriesForOtherPlatformsUnsafeMediaAndBadLinksAreDropped() throws {
        let json = #"""
        {"schemaVersion":1,"version":"0.66.0","channel":"stable","date":"2026-10-07","headline":{"en":"H"},
         "entries":[
          {"id":"phone","category":"new","title":{"en":"T"},"summary":{"en":"S"},"docs":"https://cmux.com","platforms":["ios"],"audience":"all"},
          {"id":"mac","category":"new","title":{"en":"T"},"summary":{"en":"S"},"platforms":["macos"],"audience":"all",
           "media":{"kind":"image","light":"media/../../etc/passwd","dark":"media/x-dark.png","alt":{"en":"A"}},
           "tryIt":{"deeplink":"https://evil.example"},"docs":"http://insecure.example"}
         ]}
        """#
        let document = try #require(WhatsNewDocument.decode(Data(json.utf8), origin: .bundled))
        #expect(document.entries.map(\.id) == ["mac"])
        #expect(document.entries[0].media == nil)
        #expect(document.entries[0].tryIt == nil)
        #expect(document.entries[0].docs == nil)
    }

    @Test func anUnreadableDocumentIsDroppedNotFatal() {
        #expect(WhatsNewDocument.decode(Data("{}".utf8), origin: .bundled) == nil)
        #expect(WhatsNewDocument.decode(Data(#"{"schemaVersion":2,"version":"1.0.0","channel":"stable","date":"d","headline":{"en":"h"},"entries":[]}"#.utf8), origin: .bundled) == nil)
        #expect(WhatsNewDocument.decode(Data(#"{"schemaVersion":1,"version":"one","channel":"stable","date":"d","headline":{"en":"h"},"entries":[]}"#.utf8), origin: .bundled) == nil)
    }

    /// The signed nightly notes carry the digest; a digest the app cannot
    /// read leaves the notes readable.
    @Test func releaseNotesCarryAnOptionalDigest() throws {
        let digest = try String(contentsOf: WhatsNewFixtures.sharedFixtureURL, encoding: .utf8)
        let notes = #"{"version":1,"build":"42","shortVersion":"1.0.0-nightly.42","date":"2026-10-07","highlights":[],"changes":[],"whatsNew":"#
            + digest + "}"
        let decoded = try JSONDecoder().decode(ReleaseNotes.self, from: Data(notes.utf8))
        #expect(decoded.whatsNew?.entries.count == 2)
        let broken = #"{"version":1,"build":"42","shortVersion":"1.0.0-nightly.42","date":"d","highlights":[],"changes":["a"],"whatsNew":{"nope":1}}"#
        let tolerant = try JSONDecoder().decode(ReleaseNotes.self, from: Data(broken.utf8))
        #expect(tolerant.whatsNew == nil)
        #expect(tolerant.changes == ["a"])
    }

    @Test func feedNotesBecomeADigestFromTheirEmbeddedDocumentOrHighlights() throws {
        let embedded = ReleaseNotes(version: 1, build: "42", shortVersion: "1.0.0-nightly.42", date: "2026-10-07", highlights: [], changes: [],
                                    whatsNew: WhatsNewFixtures.document("1.0.0-nightly.42", channel: .nightly))
        #expect(FeedWhatsNewSource.document(from: embedded)?.origin == .feed)
        let highlights = ReleaseNotes(version: 1, build: "43", shortVersion: "1.0.0-nightly.43", date: "2026-10-08",
                                      highlights: [.init(id: "h", title: "Hello", body: "World.", media: [],
                                                         action: .init(id: "palette.checkForUpdates", title: "Try it"))], changes: [])
        let synthesized = try #require(FeedWhatsNewSource.document(from: highlights))
        #expect(synthesized.version == "1.0.0-nightly.43")
        #expect(synthesized.entries.first?.tryIt?.action == "palette.checkForUpdates")
        let plain = ReleaseNotes(version: 1, build: "44", shortVersion: "1.0.0-nightly.44", date: "d", highlights: [], changes: ["x"])
        #expect(FeedWhatsNewSource.document(from: plain) == nil)
    }

    @Test func theFeedSourceReadsOnlyTheAskedRangeAndAtMostTheLimit() async {
        let index = (40...50).reversed().map { ReleaseNotesIndexEntry(build: "\($0)", shortVersion: "1.0.0-nightly.\($0)", date: "d", highlights: 1) }
        let asked = AskedBuilds()
        let source = FeedWhatsNewSource(index: { index }, notes: { build in
            await asked.add(build)
            return ReleaseNotes(version: 1, build: build, shortVersion: "1.0.0-nightly.\(build)", date: "d",
                                highlights: [.init(id: "h\(build)", title: "T", body: "B.", media: [], action: nil)], changes: [])
        }, limit: 4)
        let missed = await source.documents(after: WhatsNewVersion("1.0.0-nightly.45"), through: WhatsNewVersion("1.0.0-nightly.48")!)
        #expect(missed.map(\.version) == ["1.0.0-nightly.48", "1.0.0-nightly.47", "1.0.0-nightly.46"])
        let recent = await source.documents(after: nil, through: WhatsNewVersion("1.0.0-nightly.50")!)
        #expect(recent.count == 3)
        #expect(await asked.builds.count == 6)
    }

    actor AskedBuilds {
        var builds: [String] = []
        func add(_ build: String) { builds.append(build) }
    }

    @Test func theBundledSourceReadsItsIndexAndSkipsMismatchedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "whats-new-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"versions":["0.66.0","0.65.0","0.64.0"]}"#.utf8).write(to: directory.appending(path: "index.json"))
        let encoder = JSONEncoder()
        try encoder.encode(WhatsNewFixtures.document("0.66.0")).write(to: directory.appending(path: "0.66.0.json"))
        // A file whose content names another version is not trusted.
        try encoder.encode(WhatsNewFixtures.document("0.99.0")).write(to: directory.appending(path: "0.65.0.json"))
        let source = BundledWhatsNewSource(directory: directory)
        let documents = await source.documents(after: nil, through: WhatsNewVersion("0.66.0")!)
        #expect(documents.map(\.version) == ["0.66.0"])
        #expect(source.mediaURL("media/0.66.0/a-light.png")?.path.hasPrefix(directory.path) == true)
        #expect(source.mediaURL("../secret.png") == nil)
    }

    /// Only a DEV build reads a preview folder (proof screenshots, previews).
    @Test func onlyADevBuildReadsThePreviewFolder() {
        let environment = ["CMUX_NEXT_WHATS_NEW_DIR": "/tmp/whats-new-preview"]
        let dev = AppcastFixtures.identity(bundle: "com.cmuxterm.app.debug.wn", feed: nil)
        let release = AppcastFixtures.identity(bundle: "com.cmuxterm.app")
        let devSources = UpdaterService.whatsNewSources(identity: dev, environment: environment)
        #expect(devSources.compactMap { $0 as? BundledWhatsNewSource }.contains { $0.directory?.path == "/tmp/whats-new-preview" })
        let releaseSources = UpdaterService.whatsNewSources(identity: release, environment: environment)
        #expect(!releaseSources.compactMap { $0 as? BundledWhatsNewSource }.contains { $0.directory?.path == "/tmp/whats-new-preview" })
    }
}
