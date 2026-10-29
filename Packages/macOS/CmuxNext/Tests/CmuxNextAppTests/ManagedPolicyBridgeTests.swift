@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextCloud
import CmuxNextDesign
@testable import CmuxNextSettings
@testable import CmuxNextUpdater
import CmuxNextWakeups
import CmuxUpdater
import Foundation
import Testing

/// The managed policy reaches the updater and Cloud auth through a scheduled `automation`
/// observation (`ManagedPolicyBridge`). The app starts the bridge before the first settings load, so the forced
/// values it applies then must not be cleared by the still empty `managedPolicy`; a profile change after the load
/// is one automation task, which a pending key goes ahead of (p06-scheduler.md rule 9).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ManagedPolicyBridgeTests {
    /// A temporary folder with the settings file and a profile plist (`PlistManagedPreferenceReader`).
    final class Folder {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appending(path: "cnc-managed-bridge-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        var settingsFile: URL { url.appending(path: "cmux-next.json") }
        var profile: URL { url.appending(path: "profile.plist") }
        /// Writes the profile; its top-level keys are forced.
        func writeProfile(_ forced: [String: Any]) throws {
            try PropertyListSerialization.data(fromPropertyList: forced, format: .xml, options: 0).write(to: profile)
        }
    }

    /// The bridge's owners: settings on `reader`, an unstarted updater (no required update check) and Cloud auth on
    /// their own defaults.
    final class Rig {
        let folder: Folder
        let settings: SettingsController
        let updater: UpdaterService
        let auth: CloudAuth
        private let defaultsID: String

        init(folder: Folder, reader: any ManagedPreferenceReader) throws {
            let id = "test.managed-bridge.\(UUID().uuidString.lowercased())"
            defaultsID = id
            self.folder = folder
            settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: folder.settingsFile,
                                          managedReader: reader, managedWatchFiles: [])
            let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.managed-bridge", shortVersion: "1.0.0",
                                               build: "100", minimumSystemVersion: nil,
                                               infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
            let defaults = try #require(UserDefaults(suiteName: id))
            updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false, work: BackgroundWork(label: "test.managed-bridge"), deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())))
            updater.announcementsFetch = false
            let configuration = CloudConfiguration.resolve(bundleID: id, bundled: [:], process: [:], isDebugBuild: false)
            auth = CloudAuth(configuration: configuration, environment: [:], defaults: defaults)
        }

        deinit { UserDefaults.standard.removePersistentDomain(forName: defaultsID) }

        func bridge(on work: MainWorkScheduler) -> ManagedPolicyBridge {
            ManagedPolicyBridge(settings: settings, updater: updater, auth: auth, mainWork: work, appEvents: AppEvents(center: NotificationCenter()))
        }
    }

    /// AppDelegate's order: the bridge starts, then `settings.start` loads. Before the fix the observation's first
    /// apply read the empty `managedPolicy` and cleared what start had just applied.
    @Test func theForcedValuesStartAppliesSurviveUntilAndThroughTheFirstLoad() async throws {
        let forced = ManagedPreferences(forced: ["UpdateChannel": .string("stable"), "MinimumVersion": .string("9.0.0"),
                                                 "RestrictToManagedTeam": .bool(true), "ManagedTeam": .string("team_acme")])
        let rig = try Rig(folder: Folder(), reader: FixedManagedPreferenceReader(forced))
        let followers = rig.bridge(on: linklessMainWork()).start()
        #expect(rig.settings.loadCount == 0)
        #expect(rig.updater.managedMinimumVersion == "9.0.0", "start applied the forced minimum and nothing cleared it")
        #expect(rig.updater.managedChannel == .stable)
        #expect(rig.auth.managedTeamID == "team_acme", "start applied the managed team and nothing cleared it")

        await rig.settings.reload()
        runMainLoopPass(for: 0.2)
        #expect(rig.updater.managedMinimumVersion == "9.0.0", "the first load keeps the minimum")
        #expect(rig.updater.managedChannel == .stable)
        #expect(rig.auth.managedTeamID == "team_acme", "the first load keeps the managed team")
        withExtendedLifetime(followers) {}
    }

    /// p06 rule 9, automation: a profile change (another process) applies as one posted automation task, held while
    /// the person's input is pending and applied once it cleared.
    @Test func aProfileChangeIsOneAutomationTaskThatYieldsToPendingInput() async throws {
        let folder = try Folder()
        try folder.writeProfile(["MinimumVersion": "2.0.0"])
        let rig = try Rig(folder: folder, reader: PlistManagedPreferenceReader(url: folder.profile))
        await rig.settings.reload()
        let harness = FollowerHarness()
        let followers = rig.bridge(on: harness.work).start()
        #expect(rig.updater.managedMinimumVersion == "2.0.0", "the current policy applies in the caller's turn")

        try folder.writeProfile(["MinimumVersion": "3.0.0"])
        await rig.settings.reload()
        #expect(rig.settings.managedPolicy["MinimumVersion"] == .string("3.0.0"))
        #expect(rig.updater.managedMinimumVersion == "2.0.0", "nothing applies in the turn of the change")
        #expect(harness.work.postedCount(.automation) == 1, "the change is one posted automation task")

        harness.input.pending = true
        harness.frame()
        #expect(rig.updater.managedMinimumVersion == "2.0.0", "a pending key goes first: the automation flush waits")
        harness.input.pending = false
        harness.frame()
        #expect(rig.updater.managedMinimumVersion == "3.0.0", "the flush applies once the input cleared")
        harness.stop()
        withExtendedLifetime(followers) {}
    }
}
