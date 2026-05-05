import XCTest
import TerminalThemeCore

final class TerminalThemeSettingsTests: XCTestCase {
    func testTerminalThemeCustomClearsManagedThemeStateAndLegacyThemeDirectives() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-terminal-theme-custom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let configURL = TerminalThemeSettings.managedConfigURL(appSupportDirectory: appSupport)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        font-size = 15
        theme = Dracula

        # cmux themes start
        theme = light:Apple System Colors Light,dark:Apple System Colors
        # cmux themes end

        scrollback-limit = 100000
        """.write(to: configURL, atomically: true, encoding: .utf8)

        var reloadCount = 0
        let writtenURL = try TerminalThemeSettings.apply(
            .custom,
            appSupportDirectory: appSupport,
            reload: { reloadCount += 1 }
        )

        let updated = try String(contentsOf: writtenURL, encoding: .utf8)
        XCTAssertEqual(writtenURL, configURL)
        XCTAssertFalse(updated.contains("theme ="))
        XCTAssertFalse(updated.contains(TerminalThemeSettings.managedBlockStart))
        XCTAssertTrue(updated.contains("font-size = 15"))
        XCTAssertTrue(updated.contains("scrollback-limit = 100000"))
        XCTAssertEqual(reloadCount, 1)
    }

    func testTerminalThemeNamedSelectionWritesManagedThemeBlock() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-terminal-theme-named-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        var reloadCount = 0
        let writtenURL = try TerminalThemeSettings.apply(
            .named("Catppuccin Mocha"),
            appSupportDirectory: appSupport,
            reload: { reloadCount += 1 }
        )

        let updated = try String(contentsOf: writtenURL, encoding: .utf8)
        XCTAssertTrue(updated.contains(TerminalThemeSettings.managedBlockStart))
        XCTAssertTrue(updated.contains("theme = Catppuccin Mocha"))
        XCTAssertTrue(updated.contains(TerminalThemeSettings.managedBlockEnd))
        XCTAssertEqual(reloadCount, 1)
    }

    func testTerminalThemeSelectionReadsExistingManagedThemeForMigration() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-terminal-theme-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let configURL = TerminalThemeSettings.managedConfigURL(appSupportDirectory: appSupport)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        # cmux themes start
        theme = light:Apple System Colors Light,dark:Apple System Colors
        # cmux themes end
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let selection = TerminalThemeSettings.currentSelection(
            appSupportDirectory: appSupport,
            currentBundleIdentifier: TerminalThemeSettings.defaultManagedBundleIdentifier
        )

        XCTAssertEqual(selection.mode, .adaptive(light: "Apple System Colors Light", dark: "Apple System Colors"))
        XCTAssertEqual(selection.rawValue, "light:Apple System Colors Light,dark:Apple System Colors")
        XCTAssertEqual(selection.sourcePath, configURL.path)
    }

    func testTerminalThemeSelectionReadsCurrentBundleLegacyManagedConfig() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-terminal-theme-current-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let bundleIdentifier = "com.example.cmux-dev"
        let configURL = appSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        # cmux themes start
        theme = Catppuccin Mocha
        # cmux themes end
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let selection = TerminalThemeSettings.currentSelection(
            appSupportDirectory: appSupport,
            currentBundleIdentifier: bundleIdentifier
        )

        XCTAssertEqual(selection.mode, .named("Catppuccin Mocha"))
        XCTAssertEqual(selection.rawValue, "Catppuccin Mocha")
        XCTAssertEqual(selection.sourcePath, configURL.path)
    }

    func testTerminalThemeCustomClearsLegacyManagedConfigWhenCurrentConfigIsMissing() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-terminal-theme-legacy-clear-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let legacyURL = appSupport
            .appendingPathComponent(TerminalThemeSettings.defaultManagedBundleIdentifier, isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        # cmux themes start
        theme = Catppuccin Mocha
        # cmux themes end
        """.write(to: legacyURL, atomically: true, encoding: .utf8)

        let writtenURL = try TerminalThemeSettings.apply(.custom, appSupportDirectory: appSupport)

        XCTAssertEqual(
            writtenURL,
            TerminalThemeSettings.managedConfigURL(appSupportDirectory: appSupport)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testManagedThemeWritesUseRequestedBundleIdentifier() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-terminal-theme-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let bundleIdentifier = "com.example.cmux-dev"
        let writtenURL = try TerminalThemeSettings.writeManagedThemeOverride(
            rawThemeValue: "Catppuccin Mocha",
            appSupportDirectory: appSupport,
            bundleIdentifier: bundleIdentifier
        )

        XCTAssertEqual(
            writtenURL,
            TerminalThemeSettings.managedConfigURL(
                appSupportDirectory: appSupport,
                bundleIdentifier: bundleIdentifier
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: TerminalThemeSettings.managedConfigURL(appSupportDirectory: appSupport).path
            )
        )

        let clearedURL = try TerminalThemeSettings.clearManagedThemeOverride(
            appSupportDirectory: appSupport,
            bundleIdentifier: bundleIdentifier
        )

        XCTAssertEqual(clearedURL, writtenURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writtenURL.path))
    }

    func testTerminalThemeNamesWithReservedDelimitersAreNotSelectableOrWritable() throws {
        let resourcesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-terminal-theme-names-\(UUID().uuidString)")
        let themesDirectory = resourcesDirectory.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resourcesDirectory) }

        for name in ["Good Theme", "Bad, Theme", "Bad: Theme"] {
            let url = themesDirectory.appendingPathComponent(name, isDirectory: false)
            try "".write(to: url, atomically: true, encoding: .utf8)
        }

        let names = TerminalThemeSettings.availableThemeNames(
            environment: ["GHOSTTY_RESOURCES_DIR": resourcesDirectory.path],
            bundleResourceURL: nil,
            fileManager: .default
        )
        let commaSelection = TerminalThemeSettings.parseSelection(rawValue: "Bad, Theme", sourcePath: nil)
        let colonSelection = TerminalThemeSettings.parseSelection(rawValue: "light:Bad: Theme,dark:Good Theme", sourcePath: nil)

        XCTAssertEqual(names, ["Good Theme"])
        XCTAssertNil(TerminalThemeMode.named("Bad, Theme").rawThemeValue)
        XCTAssertNil(TerminalThemeSettings.encodedThemeValue(light: "Bad: Theme", dark: "Good Theme"))
        XCTAssertEqual(commaSelection.mode, .custom)
        XCTAssertEqual(colonSelection.mode, .custom)
    }

    func testUnknownKeyedThemeTokenIsMalformed() {
        let selection = TerminalThemeSettings.parseSelection(rawValue: "Solarized:Dark", sourcePath: nil)

        XCTAssertEqual(selection.mode, .custom)
        XCTAssertEqual(selection.rawValue, "Solarized:Dark")
        XCTAssertNil(selection.light)
        XCTAssertNil(selection.dark)
    }
}
