import Foundation
@preconcurrency import Sparkle
import Testing
@testable import CmuxUpdater

/// cmux-next held a staged nightly for 12 hours while about 25 newer ones shipped (2026-10-21).
/// Its defaults had `SUAutomaticallyUpdate` on (the legacy NIGHTLY app shares the domain), so
/// Sparkle's scheduled check ran its own silent driver: it downloaded, handed over only an
/// install-now block through `willInstallUpdateOnQuit`, and with that delegate answering YES
/// Sparkle ran no check again until the app quit. Background installs (cmux-next) route every
/// check through this app's driver instead, without writing the shared defaults.
@MainActor
@Suite(.serialized) struct SilentDriverRoutingTests {
    /// A host bundle whose Sparkle settings live in their own defaults suite, with automatic
    /// checks and `SUAutomaticallyUpdate` on, as on the Mac in the incident.
    private struct Host {
        let bundle: Bundle
        let defaults: UserDefaults
        let domain: String
        let folder: URL

        init() throws {
            domain = "com.cmuxterm.tests.silent-driver.\(UUID().uuidString)"
            folder = FileManager.default.temporaryDirectory.appending(path: domain, directoryHint: .isDirectory)
            let contents = folder.appending(path: "Host.app/Contents", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": domain, "CFBundlePackageType": "APPL",
                                       "CFBundleVersion": "100", "CFBundleShortVersionString": "1.0.0"]
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: contents.appending(path: "Info.plist"))
            bundle = try #require(Bundle(url: folder.appending(path: "Host.app", directoryHint: .isDirectory)))
            defaults = try #require(UserDefaults(suiteName: domain))
            defaults.set(true, forKey: UpdateSettings.automaticChecksKey)
            defaults.set(true, forKey: UpdateSettings.automaticallyUpdateKey)
        }

        func remove() {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @Test func backgroundInstallsNeverRunSparklesSilentDriver() throws {
        let host = try Host()
        defer { host.remove() }
        let controller = UpdateController(log: NoopUpdateLog(), hostBundle: host.bundle, defaults: host.defaults)
        #expect(controller.updater.automaticallyDownloadsUpdates, "precondition: SUAutomaticallyUpdate is on in the host's defaults")

        controller.installsUpdatesInBackground = true
        #expect(!controller.updater.automaticallyDownloadsUpdates,
                "a scheduled check would still take Sparkle's silent driver, which stalls every later check while its update waits")
        #expect(host.defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey), "the shared defaults were rewritten")

        controller.installsUpdatesInBackground = false
        #expect(controller.updater.automaticallyDownloadsUpdates, "the prompt-driven flow no longer honors SUAutomaticallyUpdate")
    }

    /// Sparkle resumes an installer still waiting from an earlier check (the one a supersede
    /// just cancelled, if its helper has not exited yet) as "update found" at the Installing
    /// stage, where Install relaunches at once. A background install holds it as the staged
    /// update instead of relaunching nobody asked for.
    @Test func aResumedInstallerIsHeldNotInstalled() throws {
        let harness = Harness()
        harness.controller.installsUpdatesInBackground = true
        let item = try #require(SUAppcastItem(dictionary: [
            "title": "cmux 1.0.1",
            "enclosure": ["url": "https://example.com/cmux.zip", "length": "1024",
                          "sparkle:version": "101", "sparkle:shortVersionString": "1.0.1"],
        ]))
        let box = ChoiceBox()
        harness.controller.driver.showUpdateFound(with: item, state: try Self.state(stage: .installing), reply: { choice in
            MainActor.assumeIsolated { box.choice = choice }
        })
        #expect(box.choice == nil, "the resumed installer was told to install and relaunch now")
        #expect(harness.controller.stagedUpdate?.versionString == "101")
        #expect(harness.controller.cancelStagedUpdate())
        #expect(box.choice == .skip, "cancelling the held installer did not reach Sparkle")
    }

    /// A real `SPUUserUpdateState` (its initializer is Sparkle-private; it decodes from a coder).
    static func state(stage: SPUUserUpdateStage, userInitiated: Bool = false) throws -> SPUUserUpdateState {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(stage.rawValue, forKey: "SPUUserUpdateStateStage")
        archiver.encode(userInitiated, forKey: "SPUUserUpdateStateUserInitiated")
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = false
        return try #require(SPUUserUpdateState(coder: unarchiver))
    }
}
