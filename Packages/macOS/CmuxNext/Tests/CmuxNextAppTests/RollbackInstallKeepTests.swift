@testable import CmuxNextUpdater
import CmuxUpdater
import Foundation
import Testing

/// The install's keep for rollback (``UpdaterService/updaterWillInstallUpdate(build:)``): Sparkle never
/// replaces the running bundle with no kept copy, also when quit's bounded drain cut the staged keep off.
@MainActor @Suite struct RollbackInstallKeepTests {
    static let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.rollback-keep", shortVersion: "1.0.0",
                                              build: "100", minimumSystemVersion: nil,
                                              infoFeedURL: "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml",
                                              hasPublicKey: false)

    /// An updater whose kept versions and running bundle are in a temporary folder.
    static func updater() throws -> (UpdaterService, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "rollback-keep-\(UUID().uuidString)", directoryHint: .isDirectory)
        let bundle = folder.appending(path: "cmux NEXT.app", directoryHint: .isDirectory)
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleVersion": "100", "CFBundleShortVersionString": "1.0.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        let defaults = try #require(UserDefaults(suiteName: "RollbackInstallKeepTests.\(UUID().uuidString)"))
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false,
                                     keptVersionsRoot: folder.appending(path: "versions", directoryHint: .isDirectory),
                                     runningBundle: bundle)
        return (updater, folder)
    }

    @Test func anInstallKeepsTheBundleWhenTheStagedKeepIsStillRunning() throws {
        let (updater, folder) = try Self.updater()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Quit's 250 ms drain cut the staged keep off: it never reported done.
        updater.keptRunningBuild = .running
        updater.updaterWillInstallUpdate(build: "200")
        #expect(updater.keptVersions.list().map(\.build) == ["100"])
    }

    @Test func anInstallAfterACompleteStagedKeepKeepsNothingMore() throws {
        let (updater, folder) = try Self.updater()
        defer { try? FileManager.default.removeItem(at: folder) }
        updater.keptRunningBuild = .kept
        updater.updaterWillInstallUpdate(build: "200")
        #expect(updater.keptVersions.list().isEmpty)
    }

    @Test func aKeepCutOffBeforeItsRenameLeavesNoRollbackTarget() throws {
        let (updater, folder) = try Self.updater()
        defer { try? FileManager.default.removeItem(at: folder) }
        // What a cut-off keep leaves: only its hidden partial clone.
        let build = folder.appending(path: "versions/100", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: build.appending(path: ".cmux NEXT.app.partial-cut", directoryHint: .isDirectory),
                                                withIntermediateDirectories: true)
        #expect(updater.keptVersions.list().isEmpty)
        // The install's keep then replaces it with a complete one.
        updater.keptRunningBuild = .running
        updater.updaterWillInstallUpdate(build: "200")
        #expect(updater.keptVersions.list().map(\.build) == ["100"])
    }
}
