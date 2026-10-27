import CmuxNextActions
import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
@testable import CmuxNextSettings
import Foundation
import Testing

/// p08-startup-106: the four settings migrations are pure transforms of the file's text that every load
/// applies, the launch read included, so the first snapshot (and the first frame) already has the migrated
/// keys; the file gets the same edits once, in an afterStartup post. Before, they ran after the launch settled
/// (up to 4 s) and the first window showed the legacy values.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct LaunchMigrationTests {
    static let noManaged = ManagedPreferences()

    static func read(_ text: String, managed: ManagedPreferences = noManaged) async throws -> (SettingsController.LaunchRead, URL) {
        let url = try SettingsLaunchReadTests.file(text)
        return (try await SettingsLaunchReadTests.endedRead(of: url, managed: managed), url)
    }

    static func text(at url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    static func removeDirectory(of url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    /// A legacy `tabs.hiddenButtons` file: the launch read's snapshot, and so the first frame's tab bar
    /// (`PaneToolbarButtonsSetting.current`), has the pinned list the old row showed; the read writes nothing.
    @Test func aLegacyHiddenButtonsFileShowsTheMigratedTabBarInTheFirstSnapshot() async throws {
        let text = #"{ "tabs": { "hiddenButtons": ["splitDown"], "newTabKind": "terminal" } }"#
        let (read, url) = try await Self.read(text)
        defer { Self.removeDirectory(of: url) }
        let migrated = ["splitRight", "openDiffViewer", "file.open", "toggleSplitZoom"]
        #expect(PaneToolbarButtonsSetting.read(read.snapshot.root).pinned == migrated)
        #expect(read.snapshot.root.value(at: PaneToolbarButtonsSetting.legacyHiddenPath) == nil)
        #expect(!read.snapshot.retiredKeys.contains("tabs.hiddenButtons"))
        #expect(try Self.text(at: url) == text, "the launch read wrote the file")

        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(Self.noManaged), managedWatchFiles: [],
                                          launch: read)
        settings.start()
        defer { settings.stop() }
        #expect(settings.loadCount == 1)
        #expect(PaneToolbarButtonsSetting.current(settings).pinned == migrated)
        #expect(settings.fileRoot.value(at: PaneToolbarButtonsSetting.legacyHiddenPath) == nil)
    }

    /// Today's classic fixture (`ClassicSettingsUpgradeTests`): the first snapshot has every moved key.
    @Test func theClassicFixtureReadsMigratedAtLaunch() async throws {
        let (read, url) = try await Self.read(ClassicSettingsUpgradeTests.classic)
        defer { Self.removeDirectory(of: url) }
        for (path, value) in ClassicSettingsUpgradeTests.expected {
            #expect(read.snapshot.root.value(at: path) == value, "\(path.joined(separator: "."))")
        }
        #expect(read.snapshot.root.value(at: ["app", "newWorkspacePlacement"]) == nil)
        #expect(read.snapshot.root.value(at: ["app", "globalFontMagnification"]) == .number(120))
        #expect(read.snapshot.root.value(at: ["notifications", "unreadPaneRing"]) == .bool(true))
        #expect(read.snapshot.root.value(at: ["notifications", "attention", "style"]) == nil)
    }

    /// The load's text is the text the four file migrations write, one after another, in the launch's order.
    @Test func theLoadReadsWhatTheFileMigrationsWrite() async throws {
        let text = """
        {
          // a comment survives
          "app": { "quitBehavior": "end", "newWorkspacePlacement": "end" },
          "sidebar": { "showWorkspaceDirectory": false, "showCounts": true, "showBranchDirectory": true },
          "tabs": { "hiddenButtons": ["splitRight", "openDiffViewer"] }
        }
        """
        let (read, url) = try await Self.read(text)
        defer { Self.removeDirectory(of: url) }
        let root = read.snapshot.root
        #expect(root.value(at: QuitBehaviorSetting.configPath) == .string("end-keep-layout"))
        // The S1 key moves first, so classic's "Show Branch + Directory" finds its directory row set.
        #expect(root.value(at: ["sidebar", "workspaceRow", "directory"]) == .bool(false))
        #expect(root.value(at: ["sidebar", "workspaceRow", "branch"]) == .bool(true))
        #expect(root.value(at: ["sidebar", "workspaceRow", "tabCount"]) == .bool(true))
        #expect(root.value(at: ["workspaces", "newPlacement"]) == .string("bottom"))
        #expect(PaneToolbarButtonsSetting.read(root).pinned == ["splitDown", "file.open", "toggleSplitZoom"])
        for legacy in [["sidebar", "showWorkspaceDirectory"], ["sidebar", "showCounts"], ["sidebar", "showBranchDirectory"],
                       ["app", "newWorkspacePlacement"], PaneToolbarButtonsSetting.legacyHiddenPath] {
            #expect(root.value(at: legacy) == nil, "\(legacy.joined(separator: "."))")
        }

        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(Self.noManaged), managedWatchFiles: [])
        #expect(try await settings.migrateLegacyQuitBehavior())
        #expect(try await settings.migrateLegacyWorkspaceRowKeys())
        #expect(try await settings.migrateLegacyPaneToolbarButtons())
        #expect(try await settings.migrateClassicSettings())
        let written = try Self.text(at: url)
        #expect(written == read.loaded.inputs.source)
        #expect(written.contains("// a comment survives"))
    }

    /// The write-back is an afterStartup post: once startup completes it writes the text the launch read
    /// showed, and the reload after it applies nothing new.
    @Test func theWriteBackAfterStartupWritesWhatTheLaunchReadShowed() async throws {
        let text = #"{ "app": { "quitBehavior": "end" }, "tabs": { "hiddenButtons": ["splitDown"] } }"#
        let (read, url) = try await Self.read(text)
        defer { Self.removeDirectory(of: url) }
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(Self.noManaged), managedWatchFiles: [],
                                          launch: read)
        settings.start()
        defer { settings.stop() }
        let first = settings.snapshot
        let s = StartupTestScheduler()
        settings.postLaunchMigrationWrites(on: s.startup, work: s.background, classicMarker: nil)
        #expect(try Self.text(at: url) == text, "the migrations were written before startup completed")

        s.complete()
        s.fire()
        // The write's own reload comes after it publishes; the watcher's first reload may come before.
        while try Self.text(at: url) != read.loaded.inputs.source {
            await settings.waitForLoad(atLeast: settings.loadCount + 1)
        }
        #expect(settings.snapshot == first)
        // Nothing is left to write.
        #expect(await settings.writeLaunchMigrations(classicMarker: nil) == false)
    }

    /// A managed `tabs.toolbarButtons` keeps its value; the old key still goes, and an emptied `tabs` is pruned.
    @Test func aManagedTabBarListGetsNoEditAndTheOldKeyGoes() async throws {
        let managed = ManagedPreferences(forced: ["tabs.toolbarButtons": .array([.string("splitRight")])])
        let (read, url) = try await Self.read(#"{ "tabs": { "hiddenButtons": ["splitDown"] } }"#, managed: managed)
        defer { Self.removeDirectory(of: url) }
        #expect(read.loaded.effective.fileRoot.value(at: ["tabs"]) == nil)
        #expect(PaneToolbarButtonsSetting.read(read.snapshot.root).pinned == ["splitRight"])
    }

    /// Every old button hidden: the pinned list is the default, so the old key goes and `tabs` with it.
    @Test func everyOldButtonHiddenLeavesTheDefaultAndPrunesTabs() async throws {
        let (read, url) = try await Self.read(
            #"{ "tabs": { "hiddenButtons": ["splitRight", "splitDown", "openDiffViewer", "file.open", "toggleSplitZoom"] } }"#)
        defer { Self.removeDirectory(of: url) }
        #expect(read.loaded.effective.fileRoot.value(at: ["tabs"]) == nil)
        #expect(PaneToolbarButtonsSetting.read(read.snapshot.root) == .fallback)
    }

    /// A file with no legacy key reads as it is; a bad S1 value stays (with its diagnostic), as the file
    /// migration leaves it.
    @Test func filesWithNothingToMoveReadAsTheyAre() async throws {
        let plain = #"{ "appearance": { "density": "compact" } }"#
        let (read, url) = try await Self.read(plain)
        defer { Self.removeDirectory(of: url) }
        #expect(read.loaded.inputs.source == plain)

        let bad = #"{ "sidebar": { "showCounts": "yes" } }"#
        let (badRead, badURL) = try await Self.read(bad)
        defer { Self.removeDirectory(of: badURL) }
        #expect(badRead.loaded.inputs.source == bad)
        #expect(badRead.snapshot.root.value(at: ["sidebar", "showCounts"]) == .string("yes"))
    }
}
