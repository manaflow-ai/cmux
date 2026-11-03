import Foundation
@testable import CmuxNextUpdater
import Testing

/// An install that fails after the app quit says why (Leo 2026-10-21: "If an installed update ever
/// fails, the app must say why instead of offering Restart again."). The relaunch records which
/// build it installs over which; a launch still on the old build reads that as a failed install,
/// and the staged update card for that build names the cause instead of Restart to Update.
@MainActor @Suite(.serialized) struct UpdateInstallCheckTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "UpdateInstallCheckTests.\(UUID().uuidString)")!
    }

    private static func updater(defaults: UserDefaults, build: String = "100", at time: Date = start) -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.install-check", shortVersion: "1.0.0",
                                           build: build, minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        return UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                              enableSparkle: false, recordsUpdates: false, now: { time })
    }

    @Test func aLaunchOnTheOldBuildIsAFailedInstall() {
        let record = UpdateInstallCheck(fromBuild: "100", targetBuild: "200", recordedAt: Self.start)
        let soon = Self.start.addingTimeInterval(30)
        #expect(record.outcome(runningBuild: "200", now: soon) == .installed)
        #expect(record.outcome(runningBuild: "100", now: soon) == .failed)
        #expect(record.outcome(runningBuild: "300", now: soon) == nil, "a third build was installed by hand")
        #expect(record.outcome(runningBuild: "100", now: Self.start.addingTimeInterval(UpdateInstallCheck.maxAge + 1)) == nil, "stale")
        #expect(record.outcome(runningBuild: "100", now: Self.start.addingTimeInterval(-3600)) == nil, "written in the future")
        let same = UpdateInstallCheck(fromBuild: "100", targetBuild: "100", recordedAt: Self.start)
        #expect(same.outcome(runningBuild: "100", now: soon) == nil, "a reinstall of the running build judges nothing")
    }

    @Test func consumeReadsTheRecordOnce() {
        let defaults = Self.defaults()
        UpdateInstallCheck.write(UpdateInstallCheck(fromBuild: "100", targetBuild: "200", recordedAt: Self.start), defaults: defaults)
        #expect(UpdateInstallCheck.consume(defaults: defaults, build: "100", now: Self.start)?.outcome == .failed)
        #expect(UpdateInstallCheck.consume(defaults: defaults, build: "100", now: Self.start) == nil, "used once")

        defaults.set(Data("not json".utf8), forKey: UpdateInstallCheck.key)
        #expect(UpdateInstallCheck.consume(defaults: defaults, build: "100") == nil)
        #expect(defaults.data(forKey: UpdateInstallCheck.key) == nil)
    }

    @Test func theRelaunchRecordsTheInstallAndTheNextLaunchJudgesIt() throws {
        let defaults = Self.defaults()
        let before = Self.updater(defaults: defaults)
        before.installingBuild = "200"
        before.updaterWillRelaunchApplication()
        let record = try #require(defaults.data(forKey: UpdateInstallCheck.key).flatMap { try? JSONDecoder().decode(UpdateInstallCheck.self, from: $0) })
        #expect(record == UpdateInstallCheck(fromBuild: "100", targetBuild: "200", recordedAt: Self.start))

        // Sparkle put the old build back: the relaunch is still 100.
        let after = Self.updater(defaults: defaults, at: Self.start.addingTimeInterval(20))
        let failed = try #require(after.failedInstall, "a relaunch on the old build did not notice the failed install")
        #expect(failed.build == "200")
        #expect(after.log.recent.contains { $0.contains("install of 200 did not replace 100") })
        #expect(defaults.data(forKey: UpdateInstallCheck.key) == nil)
    }

    @Test func aRelaunchIntoTheNewBuildIsNoFailure() {
        let defaults = Self.defaults()
        UpdateInstallCheck.write(UpdateInstallCheck(fromBuild: "100", targetBuild: "200", recordedAt: Self.start), defaults: defaults)
        let after = Self.updater(defaults: defaults, build: "200", at: Self.start.addingTimeInterval(20))
        #expect(after.failedInstall == nil)
    }

    @Test func anInstallThatEndsWithTheAppRunningLeavesNoRecord() {
        let defaults = Self.defaults()
        let updater = Self.updater(defaults: defaults)
        updater.installingBuild = "200"
        updater.updaterWillRelaunchApplication()
        updater.abandonInstall()
        #expect(defaults.data(forKey: UpdateInstallCheck.key) == nil, "a later launch of this build would read as a failed install")
    }

    @Test func theCardForTheFailedBuildSaysWhyInsteadOfRestart() {
        let notes = UpdateReadyNotes(version: "nightly 200", notes: nil, fullNotesURL: nil)
        let failed = UpdateReadyCard(version: "nightly 200", isInstalling: false, automaticUpdates: true, notes: notes,
                                     failure: .notEnoughSpace(free: 1, needed: 2))
        #expect(failed.title == UpdaterStrings.installFailedTitle)
        #expect(failed.detail == UpdaterStrings.installFailedSpaceShort)
        #expect(failed.buttonTitle == UpdaterStrings.tryAgain)
        #expect(failed.buttonTitle != UpdaterStrings.restartToUpdate)
        #expect(failed.notes.headline == UpdaterStrings.installFailedSpace)

        let retrying = UpdateReadyCard(version: "nightly 200", isInstalling: true, automaticUpdates: true, notes: notes,
                                       failure: .notReplaced)
        #expect(retrying.title == UpdaterStrings.installingUpdate, "Try Again installs: the card says so")
        #expect(retrying.failure == nil)
    }

    @Test func onlyTheBuildWhoseInstallFailedCarriesTheReason() {
        let failed: (build: String, failure: UpdateInstallFailure)? = ("200", .notReplaced)
        #expect(UpdateInstallFailure.forStaged("200", failed: failed) == .notReplaced)
        #expect(UpdateInstallFailure.forStaged("201", failed: failed) == nil, "a newer build is a new install, offered as usual")
        #expect(UpdateInstallFailure.forStaged(nil, failed: failed) == nil)
        #expect(UpdateInstallFailure.forStaged("200", failed: nil) == nil)
    }

    @Test func diagnoseNamesTheCauseItCanSee() throws {
        let translocated = URL(filePath: "/private/var/folders/xy/T/AppTranslocation/ABC/d/cmux NIGHTLY.app")
        #expect(UpdateInstallFailure.diagnose(bundle: translocated) == .translocated)

        let root = FileManager.default.temporaryDirectory.appending(path: "UpdateInstallCheckTests-\(UUID().uuidString)")
        let bundle = root.appending(path: "cmux.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(UpdateInstallFailure.diagnose(bundle: bundle) == .notReplaced)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        #expect(UpdateInstallFailure.diagnose(bundle: bundle) == .folderNotWritable(root.path))
    }
}
