import Foundation
import Testing
@testable import CmuxSettings

/// An isolated engine over a throwaway UserDefaults suite, temp `cmux.json`, and
/// temp secret directory, so the whole control layer is exercised without the
/// app or the socket.
final class SettingsControlHarness {
    let suiteName: String
    let tempDir: URL
    let stores: SettingsControlStores
    let engine: SettingsControlEngine

    init() {
        let suiteName = "cmux.settings.test.\(UUID().uuidString)"
        self.suiteName = suiteName
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-\(UUID().uuidString)", isDirectory: true)
        tempDir = base
        let secretDir = base.appendingPathComponent("secrets", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        // Construct the suite inline so the non-Sendable UserDefaults is never
        // stored and "sent" across the actor boundary (matches the existing
        // store tests).
        let udStore = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let json = JSONConfigStore(fileURL: tempDir.appendingPathComponent("cmux.json"))
        let secret = SecretFileStore(baseDirectory: secretDir)
        stores = SettingsControlStores(defaults: udStore, json: json, secret: secret)
        engine = SettingsControlEngine(stores: stores)
    }

    func cleanup() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }
}

@Suite("SettingsControlEngine")
struct SettingsControlEngineTests {
    // MARK: - Parity (the auto-extension guarantee)

    @Test func cliKeySetEqualsCatalog() {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let catalogIDs = Set(SettingCatalog().all.map(\.id))
        #expect(Set(harness.engine.settingIDs) == catalogIDs)
        // Sorted + de-duplicated.
        #expect(harness.engine.settingIDs == harness.engine.settingIDs.sorted())
        #expect(Set(harness.engine.settingIDs).count == harness.engine.settingIDs.count)
    }

    @Test func everyCatalogEntryIsDescribeGetSetResetable() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let engine = harness.engine
        // If a future catalog entry isn't fully reachable here, this fails —
        // proving the CLI auto-extends with the catalog.
        for descriptor in engine.descriptors {
            let description = try await engine.describe(descriptor.id)
            #expect(description.id == descriptor.id)
            #expect(description.type == descriptor.valueType.name)

            _ = try await engine.get(descriptor.id)

            // Writing a value's own default is always type-valid; this exercises
            // the validate + apply path generically for every entry.
            _ = try await engine.setValue(descriptor.id, value: descriptor.defaultValue)

            let resetRow = try await engine.reset(descriptor.id)
            #expect(resetRow.isOverridden == false)
        }
    }

    // MARK: - Round-trip per value type

    @Test func roundTripBool() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let row = try await harness.engine.set("app.menuBarOnly", rawValue: "true")
        #expect(row.value == .bool(true))
        #expect(row.isOverridden)
        #expect(try await harness.engine.get("app.menuBarOnly").value == .bool(true))
    }

    @Test func roundTripInt() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let row = try await harness.engine.set("automation.portBase", rawValue: "9200")
        #expect(row.value == .int(9200))
        #expect(try await harness.engine.get("automation.portBase").value == .int(9200))
    }

    @Test func roundTripDouble() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        // Find a Double-typed setting from the catalog (no hardcoded assumption
        // about which one exists beyond its type).
        let doubleID = try #require(harness.engine.descriptors.first { $0.valueType == .double }?.id)
        let row = try await harness.engine.set(doubleID, rawValue: "0.42")
        #expect(row.value == .double(0.42))
        #expect(try await harness.engine.get(doubleID).value == .double(0.42))
    }

    @Test func roundTripString() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let row = try await harness.engine.set("app.preferredEditor", rawValue: "code -w")
        #expect(row.value == .string("code -w"))
        #expect(try await harness.engine.get("app.preferredEditor").value == .string("code -w"))
    }

    @Test func roundTripHexColorString() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        // A hex color is stored as a plain string; round-trips verbatim.
        let stringID = try #require(harness.engine.descriptors.first {
            $0.valueType == .string && $0.id.lowercased().contains("color")
        }?.id ?? harness.engine.descriptors.first { $0.valueType == .string }?.id)
        let row = try await harness.engine.set(stringID, rawValue: "#ff8800")
        #expect(row.value == .string("#ff8800"))
        #expect(try await harness.engine.get(stringID).value == .string("#ff8800"))
    }

    @Test func roundTripEnum() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let row = try await harness.engine.set("app.appearance", rawValue: "dark")
        #expect(row.value == .string("dark"))
        let description = try await harness.engine.describe("app.appearance")
        #expect(description.allowedValues == ["system", "light", "dark"])
    }

    @Test func roundTripJSONCollection() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let jsonID = try #require(harness.engine.descriptors.first {
            if case .json = $0.valueType { return $0.id != "shortcuts.bindings" }
            return false
        }?.id)
        // Try an array first, fall back to an object, depending on the setting's
        // shape — both are exercised somewhere in the catalog.
        let descriptor = try harness.engine.descriptor(for: jsonID)
        let candidate: String
        if case .array = descriptor.defaultValue { candidate = "[\"a\",\"b\"]" }
        else { candidate = "{\"k\":\"v\"}" }
        let row = try await harness.engine.set(jsonID, rawValue: candidate)
        #expect(row.isOverridden)
        #expect(try await harness.engine.get(jsonID).value == SettingJSONValue.parseJSON(candidate))
    }

    // MARK: - Validation never silently no-ops

    @Test func rejectsUnknownKey() async {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        await #expect(throws: SettingsControlError.self) {
            try await harness.engine.set("app.doesNotExist", rawValue: "x")
        }
        await #expect(throws: SettingsControlError.self) {
            _ = try await harness.engine.get("app.doesNotExist")
        }
    }

    @Test func rejectsBadBool() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        await #expect(throws: SettingsControlError.self) {
            try await harness.engine.set("app.menuBarOnly", rawValue: "maybe")
        }
        // No mutation occurred.
        #expect(try await harness.engine.get("app.menuBarOnly").isOverridden == false)
    }

    @Test func rejectsBadInt() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        await #expect(throws: SettingsControlError.self) {
            try await harness.engine.set("automation.portBase", rawValue: "1.5")
        }
        #expect(try await harness.engine.get("automation.portBase").isOverridden == false)
    }

    @Test func rejectsUnknownEnumCase() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        await #expect(throws: SettingsControlError.self) {
            try await harness.engine.set("app.appearance", rawValue: "purple")
        }
        #expect(try await harness.engine.get("app.appearance").isOverridden == false)
    }

    @Test func rejectsOutOfRangeInteger() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        // Ports must be > 0, matching the cmux.json parser's semantic bound.
        for bad in ["-1", "0"] {
            await #expect(throws: SettingsControlError.self) {
                try await harness.engine.set("automation.portBase", rawValue: bad)
            }
        }
        #expect(try await harness.engine.get("automation.portBase").isOverridden == false)
        // A valid port still goes through.
        let row = try await harness.engine.set("automation.portBase", rawValue: "8080")
        #expect(row.value == .int(8080))
    }

    // MARK: - Secret redaction

    @Test func secretIsRedactedButSettable() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let secretID = "automation.socketPassword"

        _ = try await harness.engine.set(secretID, rawValue: "hunter2")

        // The plaintext was actually written (verified against the store).
        let stored = try await harness.stores.secret.value(for: SettingCatalog().automation.socketPassword)
        #expect(stored == "hunter2")

        // But it is never surfaced by get / list / export.
        let getValue = try await harness.engine.get(secretID).value
        #expect(getValue == .string(CatalogSettingDescriptor.redactionMarker))

        let listRow = try #require(await harness.engine.list().first { $0.id == secretID })
        #expect(listRow.value == .string(CatalogSettingDescriptor.redactionMarker))

        let exportText = await harness.engine.export().jsonText
        #expect(!exportText.contains("hunter2"))
        // Secret key is omitted from export entirely.
        #expect(!exportText.contains(secretID))
    }

    // MARK: - Reset / unset

    @Test func unsetRestoresDefault() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let defaultValue = try await harness.engine.get("app.appearance").value
        _ = try await harness.engine.set("app.appearance", rawValue: "dark")
        let cleared = try await harness.engine.unset("app.appearance")
        #expect(cleared.value == defaultValue)
        #expect(cleared.isOverridden == false)
    }

    @Test func resetAllClearsEveryOverride() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        _ = try await harness.engine.set("app.menuBarOnly", rawValue: "true")
        _ = try await harness.engine.set("automation.portBase", rawValue: "9300")
        _ = try await harness.engine.set("app.devWindowDisplay", rawValue: "LG HDR 4K") // JSON-backed

        try await harness.engine.resetAll()

        for row in await harness.engine.list() {
            #expect(row.isOverridden == false, "\(row.id) still overridden after resetAll")
        }
    }

    // MARK: - Export / import

    @Test func exportImportRoundTrips() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        _ = try await harness.engine.set("app.appearance", rawValue: "dark")
        _ = try await harness.engine.set("automation.portBase", rawValue: "9400")

        let exported = await harness.engine.export()
        let text = exported.jsonText

        try await harness.engine.resetAll()
        #expect(try await harness.engine.get("app.appearance").value != .string("dark"))

        try await harness.engine.importDocument(try SettingsDocument.parse(text))
        #expect(try await harness.engine.get("app.appearance").value == .string("dark"))
        #expect(try await harness.engine.get("automation.portBase").value == .int(9400))

        // A second export equals the first.
        #expect(await harness.engine.export() == exported)
    }

    @Test func importIsAllOrNothing() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        // One good entry, one invalid enum value — the whole import must fail
        // and leave the good entry unwritten.
        let document = SettingsDocument(settings: [
            "app.appearance": .string("dark"),
            "app.confirmQuit": .string("notARealMode"),
        ])
        await #expect(throws: SettingsControlError.self) {
            try await harness.engine.importDocument(document)
        }
        #expect(try await harness.engine.get("app.appearance").isOverridden == false)
    }

    @Test func importRejectsUnknownKey() async throws {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let document = SettingsDocument(settings: ["app.nope": .bool(true)])
        await #expect(throws: SettingsControlError.self) {
            try await harness.engine.importDocument(document)
        }
    }

    // MARK: - Shortcuts

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

    @Test func shortcutListCoversEveryAction() async {
        let harness = SettingsControlHarness()
        defer { harness.cleanup() }
        let rows = await harness.engine.shortcutsList()
        #expect(Set(rows.map(\.action)) == Set(ShortcutAction.allCases.map(\.rawValue)))
    }
}
