import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The update from classic cmux (hq#1870 parity audit, cx-iy8b7): next adopts
/// the classic `cmux.json` on first launch, and its launch migration moves
/// every classic setting next reads under another key, so the person's
/// settings come over. A next key already set wins; a classic value next
/// can't express stays where it was.
@MainActor @Suite(.serialized) struct ClassicSettingsUpgradeTests {
    static let classic = """
    {
      "paneBorderColor": "#112233",
      "activePaneBorderColor": "#445566",
      "app": {
        "globalFontMagnification": 120,
        "newWorkspacePlacement": "end",
        "equalizeSplitsOnCreate": true,
        "minimalMode": false,
        "focusHistoryIncludesPanesAndTabs": true
      },
      "notifications": {
        "paneFlashColor": "#778899",
        "unreadPaneRing": true,
        "suppressWhenAppFocused": true
      },
      "diffViewer": { "defaultLayout": "unified" },
      "diff": { "layout": "split" },
      "browser": {
        "showSearchSuggestions": false,
        "defaultSearchEngine": "kagi",
        "discardHiddenWebViews": false
      },
      "sidebar": {
        "showPorts": true,
        "showLog": false,
        "showProgress": false,
        "showPullRequests": true,
        "showBranchDirectory": true,
        "showAgentActivity": false
      }
    }
    """

    static let expected: [([String], JSONValue)] = [
        (["layout", "paneBorderColor"], .string("#112233")),
        (["focusRing", "color"], .string("#445566")),
        (["notifications", "attention", "color"], .string("#778899")),
        (["workspaces", "newPlacement"], .string("bottom")),
        (["layout", "splitSizing"], .string("even")),
        (["window", "titlebar"], .string("standard")),
        (["navigation", "history", "scope"], .string("everything")),
        (["notifications", "desktop"], .string("whenInactive")),
        (["diff", "layout"], .string("split")),
        (["browser", "omnibar", "remoteSuggestions"], .bool(false)),
        (["browser", "searchEngine"], .string("kagi")),
        (["browser", "hibernation"], .string("off")),
        (["sidebar", "workspaceRow", "ports"], .bool(true)),
        (["sidebar", "workspaceRow", "log"], .bool(false)),
        (["sidebar", "workspaceRow", "progress"], .bool(false)),
        (["sidebar", "workspaceRow", "pullRequest"], .bool(true)),
        (["sidebar", "workspaceRow", "directory"], .bool(true)),
        (["sidebar", "workspaceRow", "working"], .bool(false)),
    ]

    @Test func classicSettingsComeOverOnTheUpdate() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-classic-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appending(path: ".config/cmux")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data(Self.classic.utf8).write(to: config.appending(path: "cmux.json"))

        // First launch of next: it adopts the classic file, then runs its launch migration.
        let url = try CmuxConfigFile.prepareDefaultURL(home: home, environment: [:])
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()),
                                          managedWatchFiles: [])
        await settings.reload()
        try await settings.migrateClassicSettings()

        for (path, value) in Self.expected {
            #expect(try await settings.file.value(at: path) == value, "\(path.joined(separator: "."))")
        }
        // Moved keys are gone; one next can't express (the ring on: next's default) stays.
        #expect(try await settings.file.value(at: ["app", "newWorkspacePlacement"]) == nil)
        #expect(try await settings.file.value(at: ["app", "globalFontMagnification"]) == .number(120))
        #expect(try await settings.file.value(at: ["diffViewer", "defaultLayout"]) == nil)
        #expect(try await settings.file.value(at: ["notifications", "unreadPaneRing"]) == .bool(true))
        #expect(try await settings.file.value(at: ["notifications", "attention", "style"]) == nil)
    }

    /// Classic values next would only approximate stay in classic's key
    /// rather than change what the person gets.
    @Test func approximateClassicValuesStay() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-classic-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appending(path: ".config/cmux")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data("""
        {
          "app": { "globalFontMagnification": 200 },
          "browser": { "defaultSearchEngine": "custom", "customSearchEngineURLTemplate": "https://search.example/?q={query}" },
          "notifications": { "unreadPaneRing": false },
          "sidebar": { "showBranchDirectory": true }
        }
        """.utf8).write(to: config.appending(path: "cmux.json"))

        let url = try CmuxConfigFile.prepareDefaultURL(home: home, environment: [:])
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()),
                                          managedWatchFiles: [])
        await settings.reload()
        try await settings.migrateClassicSettings()

        // Classic magnified terminals too; next's UI scale is chrome only.
        #expect(try await settings.file.value(at: ["app", "uiScale"]) == nil)
        #expect(try await settings.file.value(at: ["app", "globalFontMagnification"]) == .number(200))
        // A custom engine without its template would search with Google.
        #expect(try await settings.file.value(at: ["browser", "searchEngine"]) == nil)
        #expect(try await settings.file.value(at: ["browser", "defaultSearchEngine"]) == .string("custom"))
        // Classic's ring off kept the flash.
        #expect(try await settings.file.value(at: ["notifications", "attention", "persist"]) == .bool(false))
        #expect(try await settings.file.value(at: ["notifications", "attention", "style"]) == nil)
        // "Show Branch + Directory" is two rows in next.
        #expect(try await settings.file.value(at: ["sidebar", "workspaceRow", "branch"]) == .bool(true))
        #expect(try await settings.file.value(at: ["sidebar", "workspaceRow", "directory"]) == .bool(true))
    }
}
