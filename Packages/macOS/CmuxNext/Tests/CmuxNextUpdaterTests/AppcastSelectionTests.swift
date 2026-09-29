import Foundation
import Testing
@testable import CmuxNextUpdater

@Suite struct AppcastParserTests {
    @Test func readsItemsAndSkipsDeltaEnclosures() throws {
        let items = try AppcastParser.parse(AppcastFixtures.feed(
            AppcastFixtures.item("3658011726301", short: "0.64.25-nightly.3658011726301", minimum: "14.0", deltas: true),
            AppcastFixtures.item("200", short: "1.0.0", minimum: "26.0", maximum: "27.9")
        ))
        #expect(items.count == 2)
        #expect(items[0].version == "3658011726301")
        #expect(items[0].displayVersion == "0.64.25-nightly.3658011726301")
        #expect(items[0].minimumSystemVersion == SystemVersion("14.0"))
        #expect(items[0].downloadURL?.lastPathComponent == "cmux-macos.dmg")
        #expect(items[1].maximumSystemVersion == SystemVersion("27.9"))
        #expect(items[1].releaseNotesURL?.absoluteString == "https://github.com/manaflow-ai/cmux/releases/tag/v1.0.0")
    }

    @Test func rejectsNonFeeds() {
        #expect(throws: AppcastParseError.self) { try AppcastParser.parse(Data("<html><body>404</body></html>".utf8)) }
        #expect(throws: AppcastParseError.self) { try AppcastParser.parse(Data("not xml".utf8)) }
    }
}

/// The macOS 26 floor: what each Mac is offered once cmux-next items
/// (minimumSystemVersion 26.0) reach a feed that may still list legacy items.
@Suite struct AppcastSelectorTests {
    let macOS15 = SystemVersion(major: 15, minor: 6)
    let macOS26 = SystemVersion(major: 26, minor: 1)

    @Test func macOS26GetsTheCmuxNextBuild() {
        let items = [AppcastItem(version: "107", minimumSystemVersion: SystemVersion("26.0"))]
        #expect(AppcastSelector.select(from: items, currentBuild: "106", system: macOS26) == .updateAvailable(items[0]))
    }

    @Test func macOS15IsNeverOfferedACmuxNextBuild() {
        let next = AppcastItem(version: "107", minimumSystemVersion: SystemVersion("26.0"))
        #expect(AppcastSelector.select(from: [next], currentBuild: "106", system: macOS15)
            == .requiresNewerSystem(next, required: SystemVersion(major: 26)))
    }

    @Test func macOS15MovesToTheLastLegacyBuildWhileTheFeedListsIt() {
        let next = AppcastItem(version: "107", minimumSystemVersion: SystemVersion("26.0"))
        let lastLegacy = AppcastItem(version: "106", minimumSystemVersion: SystemVersion("14.0"))
        #expect(AppcastSelector.select(from: [next, lastLegacy], currentBuild: "105", system: macOS15) == .updateAvailable(lastLegacy))
        // Already on it: stays, and is told why the newer build is not offered.
        #expect(AppcastSelector.select(from: [next, lastLegacy], currentBuild: "106", system: macOS15)
            == .requiresNewerSystem(next, required: SystemVersion(major: 26)))
        // macOS 26 still takes the newest build.
        #expect(AppcastSelector.select(from: [next, lastLegacy], currentBuild: "105", system: macOS26) == .updateAvailable(next))
    }

    @Test func upToDateAndDowngradesAreNotOffered() {
        let items = [AppcastItem(version: "106", minimumSystemVersion: SystemVersion("14.0"))]
        #expect(AppcastSelector.select(from: items, currentBuild: "106", system: macOS26) == .upToDate(latest: items[0]))
        #expect(AppcastSelector.select(from: items, currentBuild: "200", system: macOS26) == .upToDate(latest: items[0]))
        #expect(AppcastSelector.select(from: [], currentBuild: "1", system: macOS26) == .upToDate(latest: nil))
    }

    @Test func comparesBuildNumbersLikeSparkle() {
        // Nightly builds are 13-digit numbers; string order would be wrong.
        #expect(AppcastSelector.isOlder("999999999999", than: "3658011726301"))
        #expect(AppcastSelector.isOlder("106", than: "3658011726301"))
        #expect(!AppcastSelector.isOlder("3658011726301", than: "3658011726301"))
        #expect(AppcastSelector.isOlder("9", than: "10"))
    }

    @Test func maximumSystemVersionIsHonored() {
        let capped = AppcastItem(version: "107", minimumSystemVersion: SystemVersion("14.0"), maximumSystemVersion: SystemVersion("15.9"))
        #expect(AppcastSelector.select(from: [capped], currentBuild: "106", system: macOS26) == .requiresNewerSystem(capped, required: SystemVersion("14.0")!))
        #expect(AppcastSelector.select(from: [capped], currentBuild: "106", system: macOS15) == .updateAvailable(capped))
    }
}

@Suite struct UpdateProberTests {
    @Test func probesTheArchitectureFeedWithoutInstalling() async throws {
        let fetcher = FixtureFetcher(AppcastFixtures.feed(
            AppcastFixtures.item("3658011726302", minimum: "26.0"),
            AppcastFixtures.item("3658011726301", minimum: "14.0")
        ))
        let prober = UpdateProber(fetcher: fetcher, architecture: .arm64)
        let identity = AppcastFixtures.identity(bundle: "com.cmuxterm.app.nightly", build: "3658011726300",
                                                feed: "https://files.cmux.com/nightly/appcast.xml")
        let result = try await prober.probe(identity, system: SystemVersion(major: 15, minor: 6), now: Date(timeIntervalSince1970: 0))
        #expect(fetcher.requested.map(\.absoluteString) == ["https://files.cmux.com/nightly/appcast-arm64.xml"])
        #expect(result.track == .nightly)
        #expect(result.itemCount == 2)
        #expect(result.outcome.kind == "update_available")
        guard case .updateAvailable(let item) = result.outcome else { return }
        #expect(item.version == "3658011726301")
    }
}
