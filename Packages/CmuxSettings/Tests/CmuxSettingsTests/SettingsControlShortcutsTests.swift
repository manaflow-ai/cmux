import Foundation
import Testing
@testable import CmuxSettings

/// Shortcut-subtree tests for the settings control engine (uses the shared
/// `SettingsControlHarness` from `SettingsControlEngineTests.swift`).
@Suite("SettingsControlShortcuts")
struct SettingsControlShortcutsTests {
    @Test func shortcutSetGetUnsetReset() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let engine = harness.engine

        let row = try await engine.shortcutSet("openSettings", combo: "cmd+ctrl+0")
        #expect(row.binding == "cmd+ctrl+0")
        #expect(row.isOverridden)

        #expect(try await engine.shortcutGet("openSettings").binding == "cmd+ctrl+0")

        let unset = try await engine.shortcutUnset("openSettings")
        #expect(unset.isOverridden == false)
        #expect(unset.binding == unset.defaultBinding)

        _ = try await engine.shortcutSet("openSettings", combo: "cmd+ctrl+0")
        try await engine.shortcutsReset()
        #expect(try await engine.shortcutGet("openSettings").isOverridden == false)
    }

    @Test func shortcutConflictDetection() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let engine = harness.engine

        try await engine.shortcutSet("openSettings", combo: "cmd+ctrl+9")
        // Assigning the same combo to another action conflicts.
        await #expect(throws: SettingsControlError.self) {
            try await engine.shortcutSet("newTab", combo: "cmd+ctrl+9")
        }
        // newTab was not changed.
        #expect(try await engine.shortcutGet("newTab").isOverridden == false)

        // --force overrides the conflict.
        let forced = try await engine.shortcutSet("newTab", combo: "cmd+ctrl+9", force: true)
        #expect(forced.binding == "cmd+ctrl+9")
    }

    @Test func shortcutForceUnbindsConflictingAction() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let engine = harness.engine

        _ = try await engine.shortcutSet("openSettings", combo: "cmd+ctrl+opt+7", force: true)
        // Forcing the same keystroke onto another action reassigns it: the loser
        // is unbound so the running app routes the stroke to newTab alone.
        let row = try await engine.shortcutSet("newTab", combo: "cmd+ctrl+opt+7", force: true)
        #expect(row.binding == "cmd+opt+ctrl+7")

        let openSettings = try await engine.shortcutGet("openSettings")
        #expect(openSettings.binding == "none")
        #expect(openSettings.isOverridden)
    }

    @Test func rejectsOutOfRangeNumeric() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let engine = harness.engine
        // Above max / below min / out of [0,1] are all rejected per the schema.
        await #expect(throws: SettingsControlError.self) { try await engine.set("markdown.fontSize", rawValue: "1000000") }
        await #expect(throws: SettingsControlError.self) { try await engine.set("terminal.textBoxMaxLines", rawValue: "0") }
        await #expect(throws: SettingsControlError.self) { try await engine.set("sidebarAppearance.tintOpacity", rawValue: "2") }
        // In-range values still go through.
        #expect(try await engine.set("markdown.fontSize", rawValue: "12").value == .int(12))
        #expect(try await engine.set("sidebarAppearance.tintOpacity", rawValue: "0.5").value == .double(0.5))
    }

    @Test func shortcutSystemWideHotkeyShape() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let engine = harness.engine
        // System-wide hotkeys reject chords and shift-only (non-primary) strokes.
        await #expect(throws: SettingsControlError.self) { try await engine.shortcutSet("globalSearch", combo: "ctrl+b c") }
        await #expect(throws: SettingsControlError.self) { try await engine.shortcutSet("globalSearch", combo: "shift+f") }
        // A single stroke with a primary modifier is accepted.
        let row = try await engine.shortcutSet("globalSearch", combo: "cmd+ctrl+opt+0", force: true)
        #expect(row.isOverridden)
    }

    @Test func importRollsBackOnBackendWriteFailure() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let fileManager = FileManager.default
        // Make cmux.json's directory read-only so a JSON-backed write fails.
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: harness.tempDir.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.tempDir.path) }

        // Sorted apply order: app.appearance (UserDefaults) applies, then
        // app.devWindowDisplay (cmux.json) fails — the first must roll back.
        let document = SettingsDocument(settings: [
            "app.appearance": .string("dark"),
            "app.devWindowDisplay": .string("x"),
        ])
        await #expect(throws: SettingsControlError.self) {
            try await harness.engine.importDocument(document)
        }
        #expect(try await harness.engine.get("app.appearance").isOverridden == false)
    }

    @Test func rejectsNonFiniteDouble() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let doubleID = try #require(harness.engine.descriptors.first { $0.valueType == .double }?.id)
        for bad in ["nan", "inf", "-inf"] {
            await #expect(throws: SettingsControlError.self) {
                try await harness.engine.set(doubleID, rawValue: bad)
            }
        }
        #expect(try await harness.engine.get(doubleID).isOverridden == false)
    }

    @Test func shortcutRejectsUnknownActionAndBadCombo() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        await #expect(throws: SettingsControlError.self) {
            try await harness.engine.shortcutSet("notAnAction", combo: "cmd+t")
        }
        await #expect(throws: SettingsControlError.self) {
            try await harness.engine.shortcutSet("openSettings", combo: "%%%bogus%%%")
        }
    }

    @Test func shortcutSetHonorsActionBareFirstStrokePolicy() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let engine = harness.engine

        // Vim-style diff-viewer actions accept a bare first stroke.
        let row = try await engine.shortcutSet("diffViewerScrollDown", combo: "j")
        #expect(row.binding == "j")

        // A modifier-required action rejects a bare key.
        await #expect(throws: SettingsControlError.self) {
            try await engine.shortcutSet("newTab", combo: "j")
        }
        #expect(try await engine.shortcutGet("newTab").isOverridden == false)
    }

    @Test func shortcutNumberedActionRequiresDigit() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let engine = harness.engine
        // A non-digit binding for a numbered action is rejected (the app would
        // drop it on reload), not a false success.
        await #expect(throws: SettingsControlError.self) {
            try await engine.shortcutSet("selectSurfaceByNumber", combo: "ctrl+a")
        }
        // A 1–9 digit binding is accepted.
        let row = try await engine.shortcutSet("selectSurfaceByNumber", combo: "cmd+5", force: true)
        #expect(row.binding == "cmd+5")
    }

    @Test func shortcutContextSeparatedBindingsDoNotConflict() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let engine = harness.engine
        // browserZoomIn (browser focus) and markdownZoomIn (markdown focus) can
        // share a keystroke because their focus contexts cannot coexist.
        _ = try await engine.shortcutSet("browserZoomIn", combo: "cmd+ctrl+opt+8", force: true)
        // No conflict is thrown even though the keystroke matches browserZoomIn.
        let row = try await engine.shortcutSet("markdownZoomIn", combo: "cmd+ctrl+opt+8")
        // Re-rendered in canonical modifier order (cmd, shift, opt, ctrl).
        #expect(row.binding == "cmd+opt+ctrl+8")
        #expect(row.isOverridden)
    }

    @Test func numberedDigitFamilyConflictPredicate() {
        let one = StoredShortcut(first: ShortcutStroke(key: "1", command: true))
        let two = StoredShortcut(first: ShortcutStroke(key: "2", command: true))
        // Same modifiers + both numbered-digit actions collide as a family even
        // though the digits differ (mirrors the app's router).
        #expect(one.conflicts(with: two, selfUsesNumberedDigitMatching: true, otherUsesNumberedDigitMatching: true))
        // Without numbered matching, distinct digits do not collide.
        #expect(!one.conflicts(with: two, selfUsesNumberedDigitMatching: false, otherUsesNumberedDigitMatching: false))
        // Different modifiers never collide, even within the family.
        let twoShift = StoredShortcut(first: ShortcutStroke(key: "2", command: true, shift: true))
        #expect(!one.conflicts(with: twoShift, selfUsesNumberedDigitMatching: true, otherUsesNumberedDigitMatching: true))
    }

    @Test func malformedBindingDoesNotDropValidOnes() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        // A user's cmux.json with one valid binding and one malformed value.
        let configURL = harness.tempDir.appendingPathComponent("cmux.json")
        try #"{"shortcuts":{"bindings":{"toggleSidebar":"cmd+b","newTab":123}}}"#
            .write(to: configURL, atomically: true, encoding: .utf8)

        // The valid binding survives the malformed sibling (per-entry decode).
        #expect(try await harness.engine.shortcutGet("toggleSidebar").binding == "cmd+b")
        // And a later set does not erase it.
        _ = try await harness.engine.shortcutSet("openSettings", combo: "cmd+ctrl+opt+6", force: true)
        #expect(try await harness.engine.shortcutGet("toggleSidebar").binding == "cmd+b")
    }

    @Test func getIgnoresOverrideInvalidForAction() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        // newTab doesn't allow a bare first stroke, so the app ignores "j";
        // get must report the default, not the inactive override.
        let configURL = harness.tempDir.appendingPathComponent("cmux.json")
        try #"{"shortcuts":{"bindings":{"newTab":"j"}}}"#
            .write(to: configURL, atomically: true, encoding: .utf8)
        let row = try await harness.engine.shortcutGet("newTab")
        #expect(row.isOverridden == false)
        #expect(row.binding == row.defaultBinding)
    }

    @Test func unsetClearsLegacyUserDefaultsOverride() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let legacyKey = "shortcut.openSettings"
        let suite = UserDefaults(suiteName: harness.suiteName)!
        suite.set(Data("legacy".utf8), forKey: legacyKey)
        #expect(suite.object(forKey: legacyKey) != nil)

        _ = try await harness.engine.shortcutUnset("openSettings")
        #expect(UserDefaults(suiteName: harness.suiteName)!.object(forKey: legacyKey) == nil)
    }

    @Test func storedShortcutDecodesEveryJSONForm() {
        #expect(StoredShortcut.decodeFromJSON("cmd+t") == StoredShortcut(first: ShortcutStroke(key: "t", command: true)))
        #expect(StoredShortcut.decodeFromJSON(["ctrl+b", "c"])
            == StoredShortcut(first: ShortcutStroke(key: "b", control: true), second: ShortcutStroke(key: "c")))
        #expect(StoredShortcut.decodeFromJSON(NSNull()) == .unbound)
        // The whole `shortcuts.bindings` map decodes mixed forms without loss.
        let raw: [String: Any] = ["newTab": "cmd+t", "prefix": ["ctrl+b", "c"]]
        #expect([String: StoredShortcut].decodeFromJSON(raw)?.count == 2)
    }

    @Test func shortcutSetPreservesExistingStringFormBindings() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        // A user's hand-written cmux.json with a string-form binding.
        let configURL = harness.tempDir.appendingPathComponent("cmux.json")
        try #"{"shortcuts":{"bindings":{"toggleSidebar":"cmd+b"}}}"#
            .write(to: configURL, atomically: true, encoding: .utf8)

        // Setting a different action must not erase the existing override.
        _ = try await harness.engine.shortcutSet("openSettings", combo: "cmd+ctrl+opt+5", force: true)
        let toggleSidebar = try await harness.engine.shortcutGet("toggleSidebar")
        #expect(toggleSidebar.isOverridden)
        #expect(toggleSidebar.binding == "cmd+b")
    }

    @Test func shortcutListCoversEveryAction() async {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let rows = await harness.engine.shortcutsList()
        #expect(Set(rows.map(\.action)) == Set(ShortcutAction.allCases.map(\.rawValue)))
    }
}
