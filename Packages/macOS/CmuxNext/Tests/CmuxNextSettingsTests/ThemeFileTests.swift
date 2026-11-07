import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// `appearance.themeFile` (Leo, 2026-11-04: "Linux ricing and the whole dot file situation"): a
/// look in `~/.config/cmux/themes/<name>.json` applies over cmux-next.json, live as the file is
/// saved, through the schema's own checks, with its text kept at 4.5:1 contrast.
@MainActor @Suite(.serialized) struct ThemeFileTests {
    static let accent = ["appearance", "accent"]
    static let borders = ["appearance", "borders"]
    static let edits = ["appearance", "themeEdits"]

    static func overlay(_ text: String, base: JSONValue = .object([:])) -> ThemeFileOverlay {
        ThemeFileOverlay(name: "tokyo", source: .success(text), base: base)
    }

    @Test func aThemeFileSetsLookSettingsNestedOrDotted() {
        let overlay = Self.overlay(#"{ "appearance": { "accent": "blue" }, "appearance.borders": "none" } // a look"#)
        #expect(overlay.isLoaded)
        #expect(overlay.diagnostics.isEmpty)
        let root = overlay.applied(to: .object(["appearance": .object(["accent": "red", "density": "compact"])]))
        #expect(root.value(at: Self.accent) == "blue")
        #expect(root.value(at: Self.borders) == "none")
        #expect(root.value(at: ["appearance", "density"]) == "compact")
    }

    @Test func aRefusedValueIsDroppedAndNamesTheFileAndKey() throws {
        let overlay = Self.overlay(#"{ "appearance": { "accent": "purple", "borders": "none" }, "terminal.fontSize": 14, "nope": 1 }"#)
        #expect(overlay.values.map(\.path) == [Self.borders])
        let accent = try #require(overlay.diagnostics.first { $0.path == "appearance.accent" })
        #expect(accent.file == "themes/tokyo.json")
        #expect(accent.value == #""purple""#)
        #expect(accent.message.hasPrefix("expected one of"))
        #expect(overlay.diagnostics.contains { $0.path == "terminal.fontSize" && $0.message == "a theme file sets only look settings" })
        #expect(overlay.diagnostics.contains { $0.path == "nope" && $0.message == "not a cmux setting" })
        // The toast names the theme file, not cmux-next.json.
        var notices = SettingsDiagnosticNotices()
        let update = notices.update(overlay.diagnostics, file: .object([:]))
        let notice = try #require(update.announce.first { $0.path == "appearance.accent" })
        let message = SettingsDiagnosticStrings.message(notice, valueLimit: 80)
        #expect(message.hasPrefix("themes/tokyo.json: appearance.accent = \"purple\" was ignored"))
    }

    @Test func aMissingOrBrokenFileIsReportedAtTheSetting() throws {
        let missing = ThemeFileOverlay(name: "gone", source: nil, base: .object([:]))
        #expect(!missing.isLoaded)
        #expect(missing.diagnostics.map(\.path) == ["appearance.themeFile"])
        #expect(missing.diagnostics.first?.file == nil)
        let broken = Self.overlay("{ not json")
        #expect(!broken.isLoaded)
        #expect(broken.isUnparsable)
        let problem = try #require(broken.diagnostics.first)
        #expect(problem.kind == .unreadableFile && problem.file == "themes/tokyo.json")
        // The toast words it as cmux-next.json's, with the theme file's name.
        let notice = SettingsDiagnosticNotices.Notice(kind: problem.kind, path: problem.path, value: nil, message: problem.message, file: problem.file)
        #expect(SettingsDiagnosticStrings.message(notice, valueLimit: 80).hasPrefix("themes/tokyo.json could not be read ("))
    }

    @Test func colorsEditTheTerminalThemeTheFileNamesAndKeepOtherEdits() {
        let base = JSONValue.object(["appearance": .object(["themeEdits": .object(["Nord/background": "#2e3440"])])])
        let overlay = Self.overlay(##"{ "appearance.theme": "Rose Pine", "colors": { "background": "#191724", "foreground": "#e0def4", "palette": ["#26233a"] } }"##, base: base)
        #expect(overlay.diagnostics.isEmpty)
        let root = overlay.applied(to: base)
        #expect(root.value(at: Self.edits) == .object([
            "Nord/background": "#2e3440", "Rose Pine/background": "#191724", "Rose Pine/foreground": "#e0def4", "Rose Pine/0": "#26233a",
        ]))
        #expect(CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).diagnostics.isEmpty)
    }

    @Test func aGhosttyBlockIsReadAsAGhosttyThemeFile() {
        let overlay = Self.overlay(#"{ "appearance.theme": "Nord", "ghostty": ["background = #2e3440", "foreground = #d8dee9", "palette = 4=#81a1c1"] }"#)
        let edits = overlay.applied(to: .object([:])).value(at: Self.edits)
        #expect(edits?["Nord/background"] == "#2e3440")
        #expect(edits?["Nord/4"] == "#81a1c1")
        #expect(Self.overlay(#"{ "ghostty": "background = #2e3440" }"#).diagnostics.map(\.path) == ["ghostty"])
    }

    /// The contrast guard: text under 4.5:1 is never painted as written.
    @Test func lowContrastTextIsCorrectedAndSettingsSaysSo() throws {
        let overlay = Self.overlay(##"{ "appearance.theme": "Nord", "colors": { "background": "#222222", "foreground": "#333333" } }"##)
        #expect(overlay.corrected == ["foreground"])
        let notice = try #require(overlay.diagnostics.first)
        #expect(notice.kind == .correctedValue)
        #expect(notice.path == "appearance.themeFile")
        #expect(!SettingsDiagnosticNotices.announces(notice.kind))
        let foreground = try #require(overlay.applied(to: .object([:])).value(at: Self.edits)?["Nord/foreground"]?.stringValue)
        let ratio = try #require(ThemeRGB(cssHex: foreground)).contrast(with: try #require(ThemeRGB(cssHex: "#222222")))
        #expect(ratio >= AppTheme.textMinimum)
        #expect(Self.overlay(##"{ "appearance.theme": "Nord", "colors": { "background": "#222222", "foreground": "#eeeeee" } }"##).corrected.isEmpty)
    }

    /// The copy-paste example in skills/cmux-customization/SKILL.md ("Rice cmux") applies whole.
    @Test func theSkillExampleAppliesWithNoRefusals() {
        let overlay = Self.overlay(#"""
        {
          "appearance.theme": "TokyoNight",
          "appearance.appTheme": "TokyoNight",
          "appearance.accent": "magenta",
          "appearance.background": "none",
          "appearance.backgroundOpacity": 0.85,
          "appearance.borders": "none",
          "appearance.glassTransparency": 0.6,
          "ui.animationSpeed": "fast",
          "colors": { "background": "#16161e", "foreground": "#c0caf5", "accent": "#bb9af7" },
        }
        """#)
        #expect(overlay.isLoaded)
        #expect(overlay.diagnostics.isEmpty)
        #expect(overlay.values.count == 9)
        let root = overlay.applied(to: .object([:]))
        #expect(CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).diagnostics.isEmpty)
    }

    @Test func theSettingTakesAPlainNameOnly() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ThemeFileSetting.configPath))
        #expect(descriptor.accepts("tokyo night"))
        for bad in ["", "../x", "a/b", ".hidden", "tokyo.json", " tokyo"] { #expect(!descriptor.accepts(.string(bad)), "\(bad)") }
        #expect(SettingsSchema.agentSettableKeys.contains("appearance.themeFile"))
    }

    // MARK: - Live

    final class Home {
        let url: URL
        var config: URL { url.appending(path: "cmux-next.json") }
        var themes: URL { url.appending(path: "themes") }
        init() throws {
            url = FileManager.default.temporaryDirectory.appending(path: "cn-theme-file-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url.appending(path: "themes"), withIntermediateDirectories: true)
        }
        func write(_ text: String, theme name: String) throws {
            try Data(text.utf8).write(to: themes.appending(path: "\(name).json"), options: .atomic)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    static func controller(_ home: Home, config: String, design: DesignSettings = DesignSettings()) throws -> SettingsController {
        try Data(config.utf8).write(to: home.config)
        return SettingsController(registry: .standard(), design: design, fileURL: home.config,
                                  managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
    }

    /// Waits until `ready` holds, at most 5 s. Returns whether it did. Every wait here is on the
    /// thing it waits for: a watcher reload takes as long as the machine needs, so a fixed sleep
    /// would pass on an idle machine and fail on a loaded one.
    static func waitUntil(_ ready: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    /// Waits until `settings` shows `accent`, at most 5 s. Returns whether it did.
    static func waitForAccent(_ accent: ThemeAccent, in settings: SettingsController) async -> Bool {
        await waitUntil { settings.snapshot.accent == accent }
    }

    @Test func theNamedFileAppliesOverCmuxNextJSONAndListsTheFolder() async throws {
        let home = try Home()
        defer { withExtendedLifetime(home) {} }
        try home.write(#"{ "appearance": { "accent": "blue", "borders": "none" } }"#, theme: "tokyo")
        try home.write(#"{ "appearance.accent": "red" }"#, theme: "ember")
        let settings = try Self.controller(home, config: #"{ "appearance": { "accent": "green", "themeFile": "tokyo" } }"#)
        await settings.reload()
        #expect(settings.snapshot.accent == .blue)
        #expect(settings.snapshot.borders == BorderMode.none)
        #expect(settings.fileRoot.value(at: Self.accent) == "green")
        #expect(settings.themeFile?.name == "tokyo")
        #expect(settings.themeFileSources.keys.sorted() == ["ember", "tokyo"])
        // Each row the file sets says so, and no toast announces it.
        let note = try #require(settings.diagnostics.first { $0.path == "appearance.accent" })
        #expect(note.kind == .setByThemeFile)
        #expect(note.pageMessage.hasPrefix("themes/tokyo.json: set by the theme file"))

        // Previewing another file shows it whole, and ending the preview restores the active one.
        let descriptor = try #require(SettingsSchema.descriptor(for: ThemeFileSetting.configPath))
        #expect(settings.preview(descriptor, "ember"))
        #expect(settings.applied.accent == .red)
        #expect(settings.applied.borders == BorderMode.default)
        settings.endPreview()
        #expect(settings.applied.accent == .blue)
    }

    /// Saving the active theme file re-applies it with no other step; the p50 and max of save to
    /// applied settings are printed (the native half of save-to-pixels).
    @Test func savingTheActiveFileReappliesItLive() async throws {
        let home = try Home()
        defer { withExtendedLifetime(home) {} }
        try home.write(#"{ "appearance.accent": "blue" }"#, theme: "tokyo")
        let settings = try Self.controller(home, config: #"{ "appearance": { "themeFile": "tokyo" } }"#)
        settings.start()
        defer { settings.stop() }
        #expect(await Self.waitForAccent(.blue, in: settings))
        var samples: [Duration] = []
        for index in 0..<20 {
            let accent: ThemeAccent = index.isMultiple(of: 2) ? .red : .blue
            let start = ContinuousClock.now
            try home.write(#"{ "appearance.accent": "\#(accent.rawValue)" }"#, theme: "tokyo")
            #expect(await Self.waitForAccent(accent, in: settings), "save \(index)")
            samples.append(ContinuousClock.now - start)
        }
        let sorted = samples.sorted()
        print("theme-file save-to-apply: p50 \(sorted[sorted.count / 2]) max \(sorted.last ?? .zero) over \(sorted.count) saves")

        // A file made after the setting names it applies too. The controller must have read the new
        // name before the file is written, or a pass would prove nothing: it would be the plain
        // "the named file applies" case again. So the wait is on the name the controller holds.
        try Data(#"{ "appearance": { "themeFile": "later" } }"#.utf8).write(to: home.config, options: .atomic)
        #expect(await Self.waitUntil { settings.themeFile?.name == "later" }, "cmux-next.json's new themeFile name")
        try home.write(#"{ "appearance.accent": "cyan" }"#, theme: "later")
        #expect(await Self.waitForAccent(.cyan, in: settings))
    }

    /// Theme Studio writes the whole edits map it shows; the theme file's colors never land in
    /// cmux-next.json, so unsetting the file leaves none of them behind.
    @Test func aWriteNeverCopiesTheThemeFilesColorsIntoCmuxNextJSON() async throws {
        let home = try Home()
        defer { withExtendedLifetime(home) {} }
        try home.write(##"{ "appearance.theme": "Nord", "colors": { "background": "#2e3440" } }"##, theme: "nord")
        let settings = try Self.controller(home, config: ##"{ "appearance": { "theme": "Nord", "themeFile": "nord", "themeEdits": { "Nord/1": "#bf616a" } } }"##)
        await settings.reload()
        let descriptor = try #require(SettingsSchema.descriptor(for: Self.edits))
        var shown = try #require(settings.snapshot.root.value(at: Self.edits)?.objectValue)
        #expect(shown["Nord/background"] == "#2e3440")
        shown["Nord/2"] = "#a3be8c"
        try await settings.setSetting(descriptor, to: .object(shown), by: .user)
        #expect(settings.fileRoot.value(at: Self.edits) == .object(["Nord/1": "#bf616a", "Nord/2": "#a3be8c"]))
        #expect(settings.snapshot.root.value(at: Self.edits)?["Nord/background"] == "#2e3440")
    }

    /// An entry both files set keeps the person's own value in cmux-next.json when Theme Studio
    /// writes the shown map back.
    @Test func aWriteKeepsThePersonsOwnEntryWhereTheThemeFileSetsTheSameKey() async throws {
        let home = try Home()
        defer { withExtendedLifetime(home) {} }
        try home.write(##"{ "appearance.theme": "Nord", "colors": { "background": "#2e3440" } }"##, theme: "nord")
        let settings = try Self.controller(home, config: ##"{ "appearance": { "theme": "Nord", "themeFile": "nord", "themeEdits": { "Nord/background": "#000000" } } }"##)
        await settings.reload()
        let descriptor = try #require(SettingsSchema.descriptor(for: Self.edits))
        var shown = try #require(settings.snapshot.root.value(at: Self.edits)?.objectValue)
        #expect(shown["Nord/background"] == "#2e3440")
        shown["Nord/2"] = "#a3be8c"
        try await settings.setSetting(descriptor, to: .object(shown), by: .user)
        #expect(settings.fileRoot.value(at: Self.edits) == .object(["Nord/background": "#000000", "Nord/2": "#a3be8c"]))
    }

    /// A save that does not parse (an editor mid-edit) keeps the last good look and is one notice,
    /// wherever the parse error moves.
    @Test func aBrokenSaveKeepsTheLastGoodLookAndIsOneNotice() async throws {
        let home = try Home()
        defer { withExtendedLifetime(home) {} }
        try home.write(#"{ "appearance.accent": "blue" }"#, theme: "tokyo")
        let settings = try Self.controller(home, config: #"{ "appearance": { "themeFile": "tokyo" } }"#)
        await settings.reload()
        #expect(settings.snapshot.accent == .blue)
        var notices = SettingsDiagnosticNotices()
        var fingerprints: Set<String> = []
        for broken in [#"{ "appearance.accent": "#, #"{ "appearance.accent": "red", "#] {
            try home.write(broken, theme: "tokyo")
            await settings.reload()
            #expect(settings.snapshot.accent == .blue)
            let problem = try #require(settings.diagnostics.first { $0.kind == .unreadableFile && $0.file == "themes/tokyo.json" })
            #expect(problem.path.isEmpty)
            let update = notices.update(settings.diagnostics, file: settings.fileRoot)
            fingerprints.formUnion(update.announce.filter { $0.file != nil }.map(\.fingerprint))
        }
        #expect(fingerprints.count == 1)
        try home.write(#"{ "appearance.accent": "red" }"#, theme: "tokyo")
        await settings.reload()
        #expect(settings.snapshot.accent == .red)
        #expect(!settings.diagnostics.contains { $0.kind == .unreadableFile })
    }

    /// A theme file that does not parse never stops cmux-next.json's own settings from applying,
    /// even with no last good text (broken from the first load).
    @Test func aBrokenThemeFileNeverHoldsBackCmuxNextJSON() async throws {
        let home = try Home()
        defer { withExtendedLifetime(home) {} }
        try home.write(#"{ "appearance.accent": "#, theme: "tokyo")
        let design = DesignSettings()
        let settings = try Self.controller(home, config: #"{ "app": { "uiScale": 1.2 }, "appearance": { "themeFile": "tokyo" } }"#, design: design)
        await settings.reload()
        #expect(settings.diagnostics.contains { $0.kind == .unreadableFile && $0.file == "themes/tokyo.json" })
        #expect(abs(design.uiScale - 1.2) < 0.001)
        try Data(#"{ "app": { "uiScale": 1.1 }, "appearance": { "themeFile": "tokyo" } }"#.utf8).write(to: home.config)
        await settings.reload()
        #expect(abs(design.uiScale - 1.1) < 0.001)
        // Its toast opens the Theme File row, not cmux-next.json.
        #expect(SettingsDiagnosticToasts.destination("", file: "themes/tokyo.json") == .row)
    }

    /// Settings lists problems; which keys the file sets is no problem.
    @Test func thePageListsNoNoteAsAProblem() async throws {
        let home = try Home()
        defer { withExtendedLifetime(home) {} }
        try home.write(#"{ "appearance.accent": "blue" }"#, theme: "tokyo")
        let settings = try Self.controller(home, config: #"{ "appearance": { "themeFile": "tokyo" } }"#)
        await settings.reload()
        #expect(settings.diagnostics.contains { $0.kind == .setByThemeFile })
        #expect(!settings.pageDiagnostics.contains { $0.kind == .setByThemeFile })
    }

    @Test func aNameThatIsNoThemeFileNameIsReported() async throws {
        let home = try Home()
        defer { withExtendedLifetime(home) {} }
        let settings = try Self.controller(home, config: #"{ "appearance": { "themeFile": "tokyo.json" } }"#)
        await settings.reload()
        #expect(settings.themeFile == nil)
        #expect(settings.diagnostics.contains { $0.path == "appearance.themeFile" && $0.kind == .invalidValue })
    }
}
