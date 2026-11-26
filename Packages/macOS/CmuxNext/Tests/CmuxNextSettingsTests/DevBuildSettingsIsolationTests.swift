@testable import CmuxNextSettings
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign
import Foundation
import Testing

/// A fresh DEV build starts from the schema's defaults and its build defaults, never from NIGHTLY's file: its
/// settings file is its own (``BuildStatePaths``), and `mobile.allowIPhoneConnections` is on by default there (DEV
/// builds pair by default) while NIGHTLY's default and file stay as they were.
@MainActor @Suite(.serialized) struct DevBuildSettingsIsolationTests {
    private static func settings(_ json: String, _ defaults: SettingsBuildDefaults) async throws -> (SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-dev-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [],
                                          buildDefaults: defaults)
        await settings.reload()
        return (settings, home)
    }

    @Test func aFreshDevBuildAllowsIPhoneConnections() async throws {
        let (settings, home) = try await Self.settings("{}", .channel(downloadsAutomatically: false, devBuild: true))
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(settings.snapshot.mobile.allowIPhoneConnections, "a fresh DEV build does not pair by default")
        #expect(try await settings.file.value(at: MobileSettings.allowIPhoneConnectionsPath) == nil, "the DEV default was written to the file")
    }

    @Test func nightlyKeepsTheSchemaDefault() async throws {
        let (settings, home) = try await Self.settings("{}", .channel(downloadsAutomatically: true, devBuild: false))
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!settings.snapshot.mobile.allowIPhoneConnections)
        #expect(SettingsBuildDefaults.channel(downloadsAutomatically: true, devBuild: false)
            == .channel(downloadsAutomatically: true))
    }

    @Test func aDevBuildsExplicitOffWins() async throws {
        let (settings, home) = try await Self.settings(#"{"mobile": {"allowIPhoneConnections": false}}"#,
                                                       .channel(downloadsAutomatically: false, devBuild: true))
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!settings.snapshot.mobile.allowIPhoneConnections)
    }

    /// The DEV build's launch file is its own: with NIGHTLY's `cmux-next.json` and classic's `cmux.json` in the
    /// home, the launch resolves the build's file and copies neither into it.
    @Test func aDevBuildsLaunchFileIsItsOwn() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-dev-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let shared = home.appending(path: ".config/cmux-next"), classic = home.appending(path: ".config/cmux")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: classic, withIntermediateDirectories: true)
        try Data(#"{"mobile": {"allowIPhoneConnections": false}}"#.utf8).write(to: shared.appending(path: "cmux-next.json"))
        try Data(#"{"theme": "classic"}"#.utf8).write(to: classic.appending(path: "cmux.json"))
        let dev = BuildStatePaths(build: BuildIdentity(bundleID: "com.cmuxterm.app.debug.my-tag", bundledTag: nil), userHome: home,
                                  applicationSupport: home.appending(path: "Library/Application Support"),
                                  caches: home.appending(path: "Library/Caches"))
        let launch = try CmuxConfigFile.prepareLaunchFile(home: home, environment: dev.environment)
        #expect(launch.url == dev.settingsFile)
        #expect(!FileManager.default.fileExists(atPath: dev.settingsFile.path), "a DEV build's file was seeded from another build's")
        let nightly = try CmuxConfigFile.prepareLaunchFile(home: home, environment: [:])
        #expect(nightly.url.standardizedFileURL == shared.appending(path: "cmux-next.json").standardizedFileURL)
    }
}
