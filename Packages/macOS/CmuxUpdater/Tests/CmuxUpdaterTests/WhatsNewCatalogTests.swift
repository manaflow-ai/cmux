import Foundation
import Testing
@testable import CmuxUpdater

@Suite struct WhatsNewCatalogTests {
    private func release(_ version: String, features: Int = 1) -> WhatsNewRelease {
        WhatsNewRelease(
            version: version,
            title: "cmux \(version)",
            features: (0..<features).map { WhatsNewRelease.Feature(title: "F\($0)", description: "D\($0)") }
        )
    }

    private var catalog: WhatsNewCatalog {
        WhatsNewCatalog(releases: [
            release("0.64.21"),
            release("0.64.25"),
            release("0.64.24", features: 0),
            release("0.64.23"),
            release("0.64.30"),
        ])
    }

    @Test func announcesReleasesAfterTheLastSeenThroughTheCurrentNewestFirst() {
        let versions = catalog.releasesToAnnounce(after: "0.64.21", through: "0.64.25").map(\.version)
        // 0.64.24 has no highlights; 0.64.30 is newer than the running build.
        #expect(versions == ["0.64.25", "0.64.23"])
    }

    @Test func nothingRecordedAnnouncesOnlyTheCurrentRelease() {
        #expect(catalog.releasesToAnnounce(after: nil, through: "0.64.25").map(\.version) == ["0.64.25"])
        #expect(catalog.releasesToAnnounce(after: nil, through: "0.64.26").isEmpty)
    }

    @Test func seenOrDowngradedAnnouncesNothing() {
        #expect(catalog.releasesToAnnounce(after: "0.64.25", through: "0.64.25").isEmpty)
        #expect(catalog.releasesToAnnounce(after: "0.64.30", through: "0.64.25").isEmpty)
    }

    @Test func announcementIsCapped() {
        let versions = catalog.releasesToAnnounce(after: "0.1.0", through: "0.64.30", limit: 2).map(\.version)
        #expect(versions == ["0.64.30", "0.64.25"])
    }

    @Test func onDemandRecapFallsBackToTheNewestReleaseAtOrBelowTheBuild() {
        #expect(catalog.recentReleases(through: "0.64.24", limit: 1).map(\.version) == ["0.64.23"])
        #expect(catalog.recentReleases(through: "0.64.26", limit: 2).map(\.version) == ["0.64.25", "0.64.23"])
    }

    @Test func versionCompareIsNumericNotLexical() {
        let comparator = WhatsNewVersionComparator()
        #expect(comparator.compare("0.64.10", "0.64.9") == .orderedDescending)
        #expect(comparator.compare("0.64", "0.64.0") == .orderedSame)
        #expect(comparator.compare("0.63.99", "0.64.0") == .orderedAscending)
    }

    @Test func decodesTheEndpointShapeLossily() throws {
        let json = """
        {"releases": [
          {"version": "0.64.25", "title": "Twenty five", "url": "https://cmux.com/docs/changelog/0.64.25",
           "hero": "http://insecure.example/hero.png",
           "features": [
             {"title": "A", "description": "a", "tryIt": "Press Cmd+K", "image": "https://cmux.com/changelog/a.png",
              "video": "https://cmux.com/changelog/a.mp4"},
             {"title": "B"},
             {"title": "C", "description": "c", "tryIt": "   "}
           ]},
          {"title": "missing version"},
          {"version": "0.64.24", "title": "Twenty four", "features": []}
        ]}
        """
        let catalog = try WhatsNewCatalog.decode(Data(json.utf8))
        #expect(catalog.releases.map(\.version) == ["0.64.25", "0.64.24"])
        let first = try #require(catalog.releases.first)
        #expect(first.url?.absoluteString == "https://cmux.com/docs/changelog/0.64.25")
        #expect(first.hero == nil)
        #expect(first.features.map(\.title) == ["A", "C"])
        #expect(first.features[0].tryIt == "Press Cmd+K")
        #expect(first.features[0].image?.absoluteString == "https://cmux.com/changelog/a.png")
        #expect(first.features[0].video?.absoluteString == "https://cmux.com/changelog/a.mp4")
        #expect(first.features[1].tryIt == nil)
    }
}
