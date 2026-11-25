import Foundation
import Testing
@testable import CmuxNextUpdater

/// The updater's decisions moved from Swift to cmux-updater-core (rfd why-swift, the updater row):
/// these pin the behaviour the Swift had, through the app FFI the app now asks.
@Suite struct UpdaterCoreParityTests {
    /// Sparkle 2.10.0's own comparator assertions (Tests/SUVersionComparisonTest.m): the order
    /// `SUStandardVersionComparator` gave `AppcastSelector.isOlder` before the move.
    @Test func versionOrderIsSparkles() {
        let cases: [(String, String, ComparisonResult)] = [
            ("1.0", "1.1", .orderedAscending), ("2.0", "1.1", .orderedDescending), ("0.1", "0.0.1", .orderedDescending),
            ("1.5.5-335d3e2", "1.5.6-b252311", .orderedAscending), ("1.5-335d3e2", "1.5.0-335d3e2", .orderedSame),
            ("1.0b1", "1.0", .orderedAscending), ("1.0b9", "1.0b10", .orderedAscending), ("1.0pre1", "1.0.0pre1", .orderedSame),
            ("1.0b1 (1234)", "1.0 (1234)", .orderedAscending), ("3.3 (5847)", "3.3.1b1 (5902)", .orderedAscending),
            ("1.1.1.1818", "1.1.1.1818.0", .orderedSame), ("201210251627", "201211051041", .orderedAscending),
            ("1203", "1204", .orderedAscending), ("1204", "1204", .orderedSame),
        ]
        for (a, b, order) in cases {
            #expect(AppcastSelector.compare(a, b) == order, "\(a) vs \(b)")
        }
        #expect(AppcastSelector.isOlder("1203", than: "1204"))
        #expect(!AppcastSelector.isOlder("1204", than: "1204"))
    }

    /// `KeptVersionStore.isNewer` was `NSString.compare(_:options: .numeric)`.
    @Test func keptOrderIsNumeric() {
        for (a, b) in [("1204", "999"), ("1.10", "1.9"), ("20261125.1", "20261124.9"), ("a10", "a2"), ("1a", "1")] {
            #expect(KeptVersionStore.isNewer(a, than: b) == (a.compare(b, options: .numeric) == .orderedDescending), "\(a) vs \(b)")
            #expect(KeptVersionStore.isNewer(b, than: a) == (b.compare(a, options: .numeric) == .orderedDescending), "\(b) vs \(a)")
        }
    }

    @Test func systemVersionParses() {
        #expect(SystemVersion("26") == SystemVersion(major: 26))
        #expect(SystemVersion(" 15.6.1\n") == SystemVersion(major: 15, minor: 6, patch: 1))
        for text in ["", "26.", "1.2.3.4", "a", "1.-1"] { #expect(SystemVersion(text) == nil, "\(text)") }
    }

    static let feed = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
      <item>
        <title>NEXT 1205</title>
        <pubDate>Sat, 10 Oct 2026 03:05:21 +0000</pubDate>
        <sparkle:version>1205</sparkle:version>
        <sparkle:shortVersionString>1.0.0-nightly.1205</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
        <sparkle:channel>cmux-next-canary</sparkle:channel>
        <description><![CDATA[New: one]]></description>
        <enclosure url="https://files.cmux.com/next/1205.dmg" length="12" sparkle:edSignature="c2ln"/>
        <sparkle:deltas><enclosure url="https://files.cmux.com/next/d.delta" sparkle:deltaFrom="1204"/></sparkle:deltas>
      </item>
      <item>
        <enclosure url="https://files.cmux.com/next/1204.dmg" sparkle:version="1204" sparkle:shortVersionString="1204s"/>
      </item>
    </channel></rss>
    """

    @Test func appcastReadsAndSelectsAsBefore() throws {
        let items = try AppcastParser.parse(Data(Self.feed.utf8))
        #expect(items.count == 2)
        let first = try #require(items.first)
        #expect(first.version == "1205")
        #expect(first.displayVersion == "1.0.0-nightly.1205")
        #expect(first.minimumSystemVersion == SystemVersion(major: 27))
        #expect(first.sparkleChannel == "cmux-next-canary")
        #expect(first.itemDescription == "New: one")
        #expect(first.listsDeltas)
        #expect(first.downloadURL == URL(string: "https://files.cmux.com/next/1205.dmg"))
        #expect(first.signature == ArchiveSignature(edSignature: "c2ln", length: 12))
        #expect(first.date == Date(timeIntervalSince1970: 1_791_601_521))
        #expect(items[1].displayVersion == "1204s")
        #expect(!items[1].listsDeltas)

        let tahoe = SystemVersion(major: 26)
        #expect(AppcastSelector.select(from: items, currentBuild: "1203", system: tahoe) == .updateAvailable(items[1]))
        #expect(AppcastSelector.select(from: items, currentBuild: "1204", system: tahoe)
            == .requiresNewerSystem(first, required: SystemVersion(major: 27)))
        #expect(AppcastSelector.select(from: items, currentBuild: "1205", system: SystemVersion(major: 27)) == .upToDate(latest: first))
        #expect(throws: AppcastParseError(message: "appcast has no <channel>")) { try AppcastParser.parse(Data("<rss/>".utf8)) }
    }

    @Test func rollbackAndRingReturnDecideAsBefore() {
        func kept(_ build: String, _ keptAt: TimeInterval?) -> KeptVersion {
            KeptVersion(build: build, shortVersion: build, bundle: URL(fileURLWithPath: "/tmp/\(build).app"), storeSchemas: ["tabs": 3],
                        teamID: "TEAM", keptAt: keptAt.map(Date.init(timeIntervalSince1970:)))
        }
        let list = [kept("1210", 50), kept("1205", 10), kept("1200", 20), kept("1190", nil)]
        #expect(RollbackDecision.previous(kept: list, running: "1206")?.build == "1200")
        #expect(RollbackDecision.previous(kept: list, running: "1195")?.build == "1190")
        #expect(RollbackDecision.previous(kept: list, running: "1100") == nil)
        #expect(RollbackDecision.decide(kept: list, build: nil, running: "1206", stored: ["tabs": 3], teamID: "TEAM") == .success(list[2]))
        #expect(RollbackDecision.decide(kept: list, build: nil, running: "1100", stored: [:], teamID: "TEAM")
            == .failure(.nothingOlder(running: "1100")))
        #expect(RollbackDecision.decide(kept: [], build: nil, running: "1", stored: [:], teamID: "TEAM") == .failure(.nothingKept))
        #expect(RollbackDecision.decide(kept: list, build: "1205", running: "1210", stored: [:], teamID: "OTHER") == .failure(.signature(list[1])))
        #expect(RollbackDecision.decide(kept: list, build: "1205", running: "1210", stored: ["tabs": 4], teamID: "TEAM")
            == .failure(.storeTooNew(store: "tabs", stored: 4, readable: 3, kept: list[1])))
        #expect(RollbackDecision.decide(kept: list, build: "1205", running: "1210", stored: ["zeta": 1, "feed": 1], teamID: "TEAM")
            == .failure(.unknownStore(store: "feed", kept: list[1])))
        var old = list[1]; old.storeSchemas = nil
        #expect(RollbackDecision.decide(kept: [old], build: "1205", running: "1210", stored: [:], teamID: "TEAM") == .failure(.predatesRollback(old)))

        let offered = [AppcastItem(version: "1200"), AppcastItem(version: "1198")]
        #expect(RingReturn.decide(installedBuild: "1200", offered: offered, promoted: [], kept: []) == RingReturn.none)
        #expect(RingReturn.decide(installedBuild: "1210", offered: offered, promoted: ["1205"], kept: [kept("1205", nil), kept("1200", nil)])
            == .goBack(kept("1205", nil)))
        #expect(RingReturn.decide(installedBuild: "1210", offered: offered, promoted: ["1205"], pulled: ["1205"],
                                  kept: [kept("1205", nil), kept("1200", nil)]) == .goBack(kept("1200", nil)))
        #expect(RingReturn.decide(installedBuild: "1210", offered: offered, promoted: [], kept: [kept("1209", nil)]) == .waits)
    }
}
