import Foundation
@testable import CmuxNextUpdater
import Testing

/// An update installed on disk while the old build still runs offers Restart to Update (Leo's NIGHTLY,
/// 2026-11-21: installed 1.0.0-nightly.4487759453601, process started 11-16 and never relaunched).
@MainActor @Suite(.serialized) struct InstalledBuildWatchTests {
    // MARK: comparison

    @Test func aHigherBuildIsNewer() {
        #expect(InstalledBuildWatch.isNewer("4487759453601", than: "4400000000000"))
        #expect(InstalledBuildWatch.isNewer("1235", than: "1234"))
        #expect(InstalledBuildWatch.isNewer("1.2.10", than: "1.2.9"))
        #expect(InstalledBuildWatch.isNewer("1.0.0-nightly.4487759453601", than: "1.0.0-nightly.4400000000000"))
    }

    @Test func theSameOlderOrBlankBuildIsNotNewer() {
        #expect(!InstalledBuildWatch.isNewer("4487759453601", than: "4487759453601"))
        #expect(!InstalledBuildWatch.isNewer("1234", than: "1235"))
        #expect(!InstalledBuildWatch.isNewer("99", than: "100"))
        #expect(!InstalledBuildWatch.isNewer("", than: "100"))
        #expect(!InstalledBuildWatch.isNewer("100", than: " "))
        #expect(!InstalledBuildWatch.isNewer(" 100 ", than: "100"))
    }

    @Test func numbersLongerThanAnIntegerCompareByDigits() {
        #expect(InstalledBuildWatch.isNewer("99999999999999999999999", than: "9999999999999999999999"))
        #expect(!InstalledBuildWatch.isNewer("0100", than: "100"))
        #expect(InstalledBuildWatch.isNewer("1.0.1", than: "1.0"))
        #expect(!InstalledBuildWatch.isNewer("1.0", than: "1.0.0"))
    }

    @Test func anUnreadableInstalledBuildOffersNothing() {
        #expect(InstalledBuildWatch.newerInstalledBuild(running: "100", installed: nil) == nil)
        let older = InstalledBuild(build: "99", shortVersion: "1.0.0")
        #expect(InstalledBuildWatch.newerInstalledBuild(running: "100", installed: older) == nil)
        let newer = InstalledBuild(build: "101", shortVersion: "1.0.1")
        #expect(InstalledBuildWatch.newerInstalledBuild(running: "100", installed: newer) == newer)
        #expect(newer.displayVersion == "1.0.1 (101)")
    }

    @Test func readsTheBundlesInfoPlist() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "InstalledBuildWatchTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "cmux.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleVersion": "4487759453601", "CFBundleShortVersionString": "1.0.0-nightly.4487759453601"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        #expect(InstalledBuildWatch.read(bundleURL: app) == InstalledBuild(build: "4487759453601", shortVersion: "1.0.0-nightly.4487759453601"))
        #expect(InstalledBuildWatch.read(bundleURL: root.appending(path: "gone.app")) == nil)
    }

    // MARK: the updater

    private static func updater(running: String, installed: @escaping () -> InstalledBuild?) -> UpdaterService {
        let defaults = UserDefaults(testSuiteName: "InstalledBuildWatchTests.\(UUID().uuidString)")!
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.nightly", shortVersion: "1.0.0", build: running,
                                           minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false)
        updater.readInstalledBuild = installed
        return updater
    }

    @Test func aNewerInstalledBuildOffersRestartToUpdateAndNeverRelaunchesByItself() {
        var relaunches = 0
        let updater = Self.updater(running: "100") { InstalledBuild(build: "101", shortVersion: "1.0.1") }
        updater.relaunchInstalledBuild = { relaunches += 1 }
        #expect(updater.restartableUpdate == nil)
        updater.checkInstalledBuild()
        #expect(updater.installedBuild?.build == "101")
        #expect(updater.restartableUpdate?.version == "1.0.1 (101)")
        #expect(updater.readyCard?.buttonTitle == UpdaterStrings.restartToUpdate)
        #expect(relaunches == 0)
        updater.installClicked()
        #expect(relaunches == 1)
    }

    @Test func theSameBuildOnDiskOffersNothing() {
        let updater = Self.updater(running: "100") { InstalledBuild(build: "100", shortVersion: "1.0.0") }
        updater.relaunchInstalledBuild = {}
        updater.checkInstalledBuild()
        #expect(updater.installedBuild == nil)
        #expect(updater.restartableUpdate == nil)
        #expect(updater.readyCard == nil)
    }

    @Test func theOfferGoesWhenTheDiskBuildIsTheRunningOneAgain() {
        var onDisk = InstalledBuild(build: "101", shortVersion: "1.0.1")
        let updater = Self.updater(running: "100") { onDisk }
        updater.relaunchInstalledBuild = {}
        updater.checkInstalledBuild()
        #expect(updater.installedBuild != nil)
        onDisk = InstalledBuild(build: "100", shortVersion: "1.0.0")
        updater.checkInstalledBuild()
        #expect(updater.installedBuild == nil)
    }

    @Test func withoutARelaunchHookNothingIsOffered() {
        let updater = Self.updater(running: "100") { InstalledBuild(build: "101", shortVersion: "1.0.1") }
        updater.relaunchInstalledBuild = nil
        updater.checkInstalledBuild()
        #expect(updater.restartableUpdate == nil)
        #expect(updater.readyCard == nil)
    }

    @Test func aDevelopmentBuildNeverChecks() {
        let defaults = UserDefaults(testSuiteName: "InstalledBuildWatchTests.\(UUID().uuidString)")!
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.stale", shortVersion: "1.0.0", build: "100",
                                           minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false)
        updater.readInstalledBuild = { InstalledBuild(build: "101", shortVersion: "1.0.1") }
        updater.checkInstalledBuild()
        #expect(updater.installedBuild == nil)
    }
}
