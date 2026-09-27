import Foundation
import Testing
@testable import CmuxFoundation

/// Covers the read and write mapping behind the native Ghostty rows in
/// Settings > Terminal: effective values folded from the config files in load
/// order, and the exact lines each row writes to cmux's config.
@Suite("Ghostty terminal options")
struct GhosttyTerminalOptionsTests {
    private let editor = CmuxGhosttyConfigSettingEditor()

    @Test("No assignments read as Ghostty's defaults")
    func defaults() {
        let options = GhosttyTerminalOptions.defaults
        #expect(options.fontFamily == nil)
        #expect(options.fontSize == 13)
        #expect(options.cursorStyle == .block)
        #expect(options.cursorBlinks)
        #expect(options.windowPaddingX == GhosttyWindowPadding(leading: 2))
        #expect(options.windowPaddingY == GhosttyWindowPadding(leading: 2))
        #expect(options.backgroundOpacity == 1)
        #expect(!options.backgroundBlurEnabled)
        #expect(options.optionAsAlt == .automatic)
        #expect(options.scrollbackLimitBytes == 50_000_000)
    }

    @Test("A later file overrides an earlier one, and invalid values are skipped")
    func lastValidValueWins() {
        let options = GhosttyTerminalOptions(directives: [
            "font-size": ["14", "15.5", "huge"],
            "cursor-style": ["bar", "triangle"],
            "cursor-style-blink": ["false"],
            "window-padding-x": ["4,8"],
            "window-padding-y": [" 6 "],
            "background-opacity": ["0.85", "1.5"],
            "macos-option-as-alt": ["left"],
            "scrollback-limit": ["10_000_000"],
        ])
        #expect(options.fontSize == 15.5)
        #expect(options.cursorStyle == .bar)
        #expect(!options.cursorBlinks)
        #expect(options.windowPaddingX == GhosttyWindowPadding(leading: 4, trailing: 8))
        #expect(options.windowPaddingY == GhosttyWindowPadding(leading: 6))
        #expect(options.backgroundOpacity == 1)
        #expect(options.optionAsAlt == .left)
        #expect(options.scrollbackLimitBytes == 10_000_000)
    }

    @Test("An empty assignment resets the option to its default")
    func emptyValueResets() {
        let options = GhosttyTerminalOptions(directives: [
            "font-size": ["18", ""],
            "macos-option-as-alt": ["true", ""],
            "cursor-style-blink": ["false", ""],
        ])
        #expect(options.fontSize == 13)
        #expect(options.optionAsAlt == .automatic)
        #expect(options.cursorBlinks)
    }

    @Test("font-family is a list: assignments append fallbacks and an empty one clears")
    func fontFamilyFolding() {
        #expect(GhosttyTerminalOptions(directives: ["font-family": ["Menlo", "Monaco"]]).fontFamilies == ["Menlo", "Monaco"])
        #expect(GhosttyTerminalOptions(directives: ["font-family": ["Menlo", "", "SF Mono"]]).fontFamily == "SF Mono")
        #expect(GhosttyTerminalOptions(directives: ["font-family": ["Menlo", ""]]).fontFamily == nil)
    }

    @Test("background-blur accepts booleans, a radius, and macOS glass styles")
    func blurSpellings() {
        func blur(_ value: String) -> Bool {
            GhosttyTerminalOptions(directives: ["background-blur": [value]]).backgroundBlurEnabled
        }
        #expect(blur("true"))
        #expect(!blur("false"))
        #expect(blur("20"))
        #expect(!blur("0"))
        #expect(blur("macos-glass-regular"))
    }

    @Test("Each change writes its key with Ghostty's spelling")
    func changeConfigValues() {
        #expect(GhosttyTerminalOptionChange.fontSize(14.5).key.rawValue == "font-size")
        #expect(GhosttyTerminalOptionChange.fontSize(14.5).configValues == ["14.5"])
        #expect(GhosttyTerminalOptionChange.cursorStyle(.blockHollow).configValues == ["block_hollow"])
        #expect(GhosttyTerminalOptionChange.cursorBlinks(false).key.rawValue == "cursor-style-blink")
        #expect(GhosttyTerminalOptionChange.cursorBlinks(false).configValues == ["false"])
        #expect(GhosttyTerminalOptionChange.windowPaddingY(GhosttyWindowPadding(leading: 12)).key.rawValue == "window-padding-y")
        #expect(GhosttyTerminalOptionChange.windowPaddingY(GhosttyWindowPadding(leading: 12)).configValues == ["12"])
        #expect(GhosttyTerminalOptionChange.backgroundOpacity(0.8).configValues == ["0.8"])
        #expect(GhosttyTerminalOptionChange.backgroundBlurEnabled(true).configValues == ["true"])
        #expect(GhosttyTerminalOptionChange.optionAsAlt(.both).key.rawValue == "macos-option-as-alt")
        #expect(GhosttyTerminalOptionChange.optionAsAlt(.both).configValues == ["true"])
        #expect(GhosttyTerminalOptionChange.optionAsAlt(.automatic).configValues == [""])
        #expect(GhosttyTerminalOptionChange.scrollbackLimitBytes(25_000_000).configValues == ["25000000"])
    }

    @Test("A font change clears inherited families before setting its own")
    func fontFamilyChangeResetsList() {
        #expect(GhosttyTerminalOptionChange.fontFamilies(["JetBrains Mono"]).configValues == ["\"\"", "\"JetBrains Mono\""])
        #expect(GhosttyTerminalOptionChange.fontFamilies([]).configValues == ["\"\""])
    }

    @Test("Choosing a font keeps the user's fallback chain behind it")
    func fontChoiceKeepsFallbacks() {
        let options = GhosttyTerminalOptions(directives: ["font-family": ["Menlo", "Symbols Nerd Font", "Apple Color Emoji"]])
        #expect(options.fontFamiliesChoosing("SF Mono") == ["SF Mono", "Symbols Nerd Font", "Apple Color Emoji"])
        // The chosen family isn't repeated when it was already a fallback.
        #expect(options.fontFamiliesChoosing("Symbols Nerd Font") == ["Symbols Nerd Font", "Apple Color Emoji"])
        #expect(options.fontFamiliesChoosing(nil) == [])
        #expect(
            GhosttyTerminalOptionChange.fontFamilies(options.fontFamiliesChoosing("SF Mono")).configValues
                == ["\"\"", "\"SF Mono\"", "\"Symbols Nerd Font\"", "\"Apple Color Emoji\""]
        )
    }

    @Test("A padding step keeps the other side of a leading,trailing pair")
    func paddingPairKeepsTrailingSide() {
        let options = GhosttyTerminalOptions(directives: ["window-padding-x": ["4,8"]])
        let change = GhosttyTerminalOptionChange.windowPaddingX(options.windowPaddingX.withLeading(5))
        #expect(change.configValues == ["5,8"])
        #expect(GhosttyWindowPadding(configValue: "4,") == nil)
        #expect(GhosttyWindowPadding(configValue: " 3 , 7 ") == GhosttyWindowPadding(leading: 3, trailing: 7))
    }

    @Test("A slider opacity with float noise still matches the value read back")
    func opacityWithFloatNoiseReflectsWrittenValue() {
        let change = GhosttyTerminalOptionChange.backgroundOpacity(0.05 * 7)
        #expect(change.configValues == ["0.35"])
        let readBack = GhosttyTerminalOptions(directives: ["background-opacity": change.configValues])
        #expect(readBack.backgroundOpacity == 0.35)
        #expect(readBack.reflects(change))
        #expect(GhosttyTerminalOptions.defaults.applying(change).backgroundOpacity == 0.35)
    }

    @Test("reflects(_:) is false when a later file overrides the written value")
    func reflectsDetectsOverride() {
        let change = GhosttyTerminalOptionChange.fontSize(16)
        let written = GhosttyTerminalOptions(directives: ["font-size": ["16"]])
        let overridden = GhosttyTerminalOptions(directives: ["font-size": ["16", "18"]])
        #expect(written.reflects(change))
        #expect(!overridden.reflects(change))
    }

    @Test("Writing a change and reading it back after the user's config yields the change")
    func writeThenReadRoundTrip() {
        let userConfig = """
        font-family = Menlo
        font-family = Monaco
        macos-option-as-alt = left
        """
        let changes: [GhosttyTerminalOptionChange] = [
            .fontFamilies(["SF Mono"]),
            .fontSize(16),
            .cursorStyle(.underline),
            .cursorBlinks(false),
            .windowPaddingX(GhosttyWindowPadding(leading: 10)),
            .windowPaddingY(GhosttyWindowPadding(leading: 0, trailing: 6)),
            .backgroundOpacity(0.75),
            .backgroundBlurEnabled(true),
            .optionAsAlt(.automatic),
            .scrollbackLimitBytes(1_000_000),
        ]
        var cmuxConfig = "theme = Dracula\n"
        var expected = GhosttyTerminalOptions.defaults
        for change in changes {
            cmuxConfig = editor.updatedContents(cmuxConfig, setting: change.key.rawValue, values: change.configValues)
            expected = expected.applying(change)
        }

        let options = GhosttyTerminalOptions(directives: Self.directives(in: [userConfig, cmuxConfig]))
        #expect(options == expected)
        #expect(options.fontFamily == "SF Mono")
        #expect(options.optionAsAlt == .automatic)
    }

    @Test("A multi-line write replaces every earlier assignment in place")
    func multiValueWriteReplacesInPlace() {
        let contents = """
        font-family = Menlo
        font-size = 12
        font-family = Monaco

        """
        let updated = editor.updatedContents(contents, setting: "font-family", values: ["\"\"", "\"SF Mono\""])
        #expect(updated == """
        font-family = ""
        font-family = "SF Mono"
        font-size = 12

        """)
        #expect(editor.updatedContents("", setting: "macos-option-as-alt", values: [""]) == "macos-option-as-alt =\n")
    }

    /// Minimal Ghostty-style directive collection over config bodies in load order.
    private static func directives(in bodies: [String]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for body in bodies {
            for line in CmuxConfigLines().split(body) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else { continue }
                let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
                var value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                result[key, default: []].append(value)
            }
        }
        return result
    }
}
