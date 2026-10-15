import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import CmuxTheme
import Foundation
import Testing

/// `appearance.fonts.*` in cmux.json (Settings > Appearance > Fonts): the text face, the code face
/// and the chat's text size reach every page with its theme (`--cmux-font-ui`, `--cmux-font-code`,
/// `--cmux-font-chat-size`, and the literal `codeFontFamily` the editor reads) and the window's own
/// text. With no key set, nothing changes: each variable is `initial`, so pages keep their faces.
@MainActor
struct AppFontsSettingTests {
    /// Loads `json` as the cmux.json, the way a settings load applies it.
    @discardableResult
    private func load(_ json: JSONValue) -> [SettingsDiagnostic] {
        let snapshot = CmuxConfigSnapshot.parse(json, validDensities: SettingsApplier.validDensities,
                                                validMetrics: SettingsApplier.validMetrics)
        return SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
    }

    private func fonts(_ members: [String: JSONValue]) -> JSONValue {
        .object(["appearance": .object(["fonts": .object(members)])])
    }

    /// The theme payload a page gets (`window.cmuxTheme.apply`).
    private func payload() throws -> [String: Any] {
        let theme = WebTheme(ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x101018), foreground: ThemeRGB(hex: 0xE8E8F0))))
        return try #require(JSONSerialization.jsonObject(with: Data(theme.payloadJSON.utf8)) as? [String: Any])
    }

    private func variable(_ name: String) throws -> String? {
        try (payload()["variables"] as? [String: String])?[name]
    }

    @Test func chosenFacesAndSizeReachPagesAndTheWindowText() throws {
        let settings = DesignSettings.shared
        let saved = (settings.terminalFontFamily, settings.terminalConfigFontFamily)
        defer { (settings.terminalFontFamily, settings.terminalConfigFontFamily) = saved; load(.object([:])) }
        (settings.terminalFontFamily, settings.terminalConfigFontFamily) = ("Fira Code", nil)

        let diagnostics = load(fonts(["ui": .string("serif"), "code": .string("Courier New"), "chatSize": .number(16)]))
        #expect(!diagnostics.contains { $0.path.hasPrefix("appearance.fonts") })
        #expect(try variable("--cmux-font-ui")?.hasPrefix("ui-serif") == true)
        #expect(try variable("--cmux-font-code")?.hasPrefix("\"Courier New\",") == true)
        #expect(try variable("--cmux-font-chat-size") == "16px")
        #expect(try payload()["codeFontFamily"] as? String == "Courier New")
        // The window's own text draws in the serif design of the system font (New York).
        let text = Typography.system(size: 13)
        #expect(text.familyName != NSFont.systemFont(ofSize: 13).familyName)
        #expect(text.pointSize == 13)

        // Unset again: today's look, and code on pages follows the terminal's face.
        load(.object([:]))
        for name in ["--cmux-font-ui", "--cmux-font-code", "--cmux-font-chat-size"] {
            #expect(try variable(name) == "initial", "\(name)")
        }
        #expect(try payload()["codeFontFamily"] as? String == "Fira Code")
        #expect(Typography.system(size: 13).familyName == NSFont.systemFont(ofSize: 13).familyName)
    }

    @Test func badValuesKeepTodaysLookAndSaySo() throws {
        defer { load(.object([:])) }
        let diagnostics = load(fonts(["ui": .string("comic"), "code": .string("Bad \"Font\""), "chatSize": .number(30)]))
        let paths = Set(diagnostics.map(\.path))
        #expect(paths.isSuperset(of: ["appearance.fonts.ui", "appearance.fonts.code", "appearance.fonts.chatSize"]))
        for name in ["--cmux-font-ui", "--cmux-font-code", "--cmux-font-chat-size"] {
            #expect(try variable(name) == "initial", "\(name)")
        }
    }

    @Test func settingsAndAgentsCanSetEachKey() {
        for key in ["appearance.fonts.ui", "appearance.fonts.code", "appearance.fonts.chatSize"] {
            #expect(SettingsSchema.descriptor(for: key.split(separator: ".").map(String.init)) != nil, "\(key)")
            #expect(SettingsSchema.agentSettableKeys.contains(key), "\(key)")
        }
    }
}
