import Foundation
import Testing
@testable import CmuxNextTerminal

/// The launch window's connecting and failure screen, its Restart question, the palette's restart and a
/// terminal's "other build" banner speak plain words (audit 4, P12): never the internal process name
/// "cmux-tui" or "build", in English and in Japanese, and the banner of a shell another version of cmux
/// runs says what the person can do about it.
@Suite struct PlainWordErrorScreensTests {
    /// The CmuxNext Sources folder, from this file's path.
    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources")

    private static let shown: [(catalog: String, keys: [String])] = [
        ("CmuxNextDaemonRecovery/Resources/Localizable.xcstrings",
         ["daemon.connecting", "daemon.recovery.restart", "daemon.recovery.confirmTitle", "daemon.recovery.confirmBody",
          "daemon.recovery.restarting", "daemon.recovery.failed"]),
        ("CmuxNextActions/ActionCatalog.xcstrings", ["action.palette.restartServer"]),
        ("CmuxNextTerminal/Resources/Localizable.xcstrings", ["terminal.link.stall.otherBuild", "terminal.link.stall.otherBuildHint"]),
    ]

    /// The `en` and `ja` values of `key` in the catalog at `path`.
    private static func values(_ key: String, in path: String) throws -> [String: String] {
        let data = try Data(contentsOf: sources.appending(path: path))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try #require((root["strings"] as? [String: Any])?[key] as? [String: Any], "\(key) is not in \(path)")
        let localizations = try #require(entry["localizations"] as? [String: Any])
        var found: [String: String] = [:]
        for locale in ["en", "ja"] {
            let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
            found[locale] = try #require(unit?["value"] as? String, "\(key) has no \(locale) value")
        }
        return found
    }

    @Test func errorScreensNeverNameTheInternalProcess() throws {
        for (catalog, keys) in Self.shown {
            for key in keys {
                for (locale, value) in try Self.values(key, in: catalog) {
                    #expect(!value.contains("cmux-tui"), "\(key) (\(locale)) names cmux-tui: \(value)")
                    #expect(!value.localizedCaseInsensitiveContains("build") && !value.contains("ビルド"),
                            "\(key) (\(locale)) says build: \(value)")
                }
            }
        }
    }

    /// A shell that another version of cmux runs: the banner says so and offers what can help, opening it in
    /// that version or closing the tab (this version cannot adopt a shell host of another record format).
    @Test func anotherVersionsShellSaysWhatToDo() {
        let text = TerminalStatusBanner.stallText(.otherBuild, strings: .terminal)
        #expect(!text.contains("cmux-tui") && !text.localizedCaseInsensitiveContains("build"), "\(text)")
        #expect(text.contains("different version of cmux"), "\(text)")
        #expect(text.contains("Open it in that version"), "\(text)")
    }
}
