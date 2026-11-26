import Foundation
@testable import CmuxNextUpdater
import Testing

/// `cmux app relaunch` (Leo, 2026-11-22: "approved ways to simply do the update and restart button's flow should
/// be available"): it answers the running and installed builds, then quits with Keep Sessions through the
/// installed-build relaunch; `--if-newer` refuses when the bundle on disk is not newer.
@MainActor @Suite(.serialized) struct RelaunchAnswerTests {
    private static func updater(running: String, installed: InstalledBuild?) -> UpdaterService {
        let defaults = UserDefaults(testSuiteName: "RelaunchAnswerTests.\(UUID().uuidString)")!
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.nightly", shortVersion: "1.0.0", build: running,
                                           minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false)
        updater.readInstalledBuild = { installed }
        return updater
    }

    @Test func aNewerInstalledBuildAnswersThenRelaunches() async throws {
        var relaunches = 0
        let updater = Self.updater(running: "100", installed: InstalledBuild(build: "101", shortVersion: "1.0.1"))
        updater.relaunchInstalledBuild = { relaunches += 1 }
        let answer = await updater.relaunchAnswer(ifNewer: true).value
        #expect(answer == .answered(["relaunching": .bool(true), "running_build": .string("100"),
                                     "installed_build": .string("101"), "newer": .bool(true)]))
        #expect(relaunches == 0)
        try await Task.sleep(for: UpdaterService.relaunchAnswerLead * 4)
        #expect(relaunches == 1)
    }

    @Test func theSameBuildRelaunchesUnlessIfNewer() async {
        var relaunches = 0
        let updater = Self.updater(running: "100", installed: InstalledBuild(build: "100", shortVersion: "1.0.0"))
        updater.relaunchInstalledBuild = { relaunches += 1 }
        let refused = await updater.relaunchAnswer(ifNewer: true).value
        #expect(refused == .refused("the installed build 100 is not newer than the running build 100"))
        let answer = await updater.relaunchAnswer(ifNewer: false).value
        guard case .answered(let fields) = answer else { Issue.record("expected an answer, got \(answer)"); return }
        #expect(fields["newer"] == .bool(false))
    }

    @Test func anUnreadableBundleOrNoRelaunchHookRefuses() async {
        let unreadable = Self.updater(running: "100", installed: nil)
        unreadable.relaunchInstalledBuild = {}
        #expect(await unreadable.relaunchAnswer(ifNewer: false).value == .refused("the app bundle on disk could not be read"))
        let noHook = Self.updater(running: "100", installed: InstalledBuild(build: "101", shortVersion: nil))
        noHook.relaunchInstalledBuild = nil
        #expect(await noHook.relaunchAnswer(ifNewer: false).value == .refused("this build cannot relaunch itself"))
    }
}
