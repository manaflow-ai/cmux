import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// D4 (cx-aha.1): the Ctrl-1…9 scheme writer. Spaces moves Select Tab to
/// Ctrl-Opt-1…9 and gives Ctrl-1…9 to Select Space; Tabs removes what
/// Spaces wrote. A digit binding the person set by hand stays.
@MainActor
@Suite struct ShortcutDigitSchemeTests {
    static func applying(_ plan: ShortcutDigitSchemePlan, to bindings: [String: JSONValue]) -> [String: JSONValue] {
        var result = bindings
        for change in plan.changes { result[change.actionID] = change.write }
        return result
    }

    @Test func spacesFromAnEmptyFileWritesBothFamilies() {
        let plan = ShortcutDigitScheme.spaces.plan(from: [:])
        let after = Self.applying(plan, to: [:])
        #expect(after["space.selectByNumber"] == "ctrl+1")
        #expect(after["selectSurfaceByNumber"] == "ctrl+opt+1")
        #expect(plan.kept.isEmpty)
        #expect(ShortcutDigitScheme.active(in: after) == .spaces)
        #expect(ShortcutDigitScheme.spaces.plan(from: after).isEmpty)
    }

    @Test func tabsRemovesWhatSpacesWrote() {
        let spaces = Self.applying(ShortcutDigitScheme.spaces.plan(from: [:]), to: [:])
        let plan = ShortcutDigitScheme.tabs.plan(from: spaces)
        #expect(Set(plan.changes.map(\.actionID)) == Set(ShortcutDigitScheme.actionIDs))
        #expect(plan.changes.allSatisfy { $0.write == nil })
        #expect(Self.applying(plan, to: spaces).isEmpty)
        #expect(ShortcutDigitScheme.active(in: [:]) == .tabs)
        #expect(ShortcutDigitScheme.tabs.plan(from: [:]).isEmpty)
    }

    /// Another binding on a digit action (a keymap preset's Cmd-1, a chord)
    /// is the person's: it stays and the file reads as no scheme.
    @Test func aDigitBindingSetByHandStays() {
        let bindings: [String: JSONValue] = ["selectSurfaceByNumber": "cmd+1", "newTab": "cmd+k"]
        let plan = ShortcutDigitScheme.spaces.plan(from: bindings)
        #expect(plan.kept == ["selectSurfaceByNumber"])
        #expect(plan.changes == [.init(actionID: "space.selectByNumber", write: "ctrl+1")])
        #expect(ShortcutDigitScheme.active(in: bindings) == nil)
        #expect(ShortcutDigitScheme.tabs.plan(from: bindings).isEmpty)
    }

    /// The catalog defaults typed by hand read as the tabs scheme, and they
    /// are the registry's defaults (one owner of the default bindings).
    @Test func theDefaultsTypedByHandReadAsTabs() {
        let registry = ActionRegistry.standard()
        let bindings: [String: JSONValue] = ["selectSurfaceByNumber": "ctrl+1", "space.selectByNumber": "ctrl+opt+1"]
        for (id, value) in bindings {
            guard case .stroke(let stroke)? = ShortcutBindingFormat.parse(value) else { Issue.record("\(id)"); continue }
            #expect(registry.descriptor(for: ActionID(rawValue: id))?.defaultShortcut == SettingsApplier.shortcut(for: stroke), "\(id)")
        }
        #expect(ShortcutDigitScheme.active(in: bindings) == .tabs)
        #expect(ShortcutDigitScheme.tabs.plan(from: bindings).isEmpty)
        #expect(ShortcutDigitScheme.spaces.plan(from: bindings).changes.count == 2)
    }

    /// The writer goes through cmux.json, and after the reload Ctrl-1
    /// follows the scheme in the registry.
    @Test func theWriterSwitchesCtrlOneInTheRegistry() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-digit-scheme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("// mine\n{\"terminal\": {\"fontSize\": 13}}\n".utf8).write(to: url)
        let registry = ActionRegistry.standard()
        let controller = SettingsController(registry: registry, design: DesignSettings(), fileURL: url)
        await controller.reload()
        #expect(try await controller.digitScheme() == .tabs)
        #expect(registry.effectiveShortcut(for: "selectSurfaceByNumber") == Shortcut("1", modifiers: [.control]))

        let plan = try await controller.applyDigitScheme(.spaces)
        #expect(!plan.isEmpty)
        await controller.reload()
        #expect(try await controller.digitScheme() == .spaces)
        #expect(registry.effectiveShortcut(for: "space.selectByNumber") == Shortcut("1", modifiers: [.control]))
        #expect(registry.effectiveShortcut(for: "selectSurfaceByNumber") == Shortcut("1", modifiers: [.control, .option]))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("// mine"), "comments stay")

        try await controller.applyDigitScheme(.tabs)
        await controller.reload()
        #expect(try await controller.digitScheme() == .tabs)
        #expect(registry.effectiveShortcut(for: "selectSurfaceByNumber") == Shortcut("1", modifiers: [.control]))
        #expect(registry.effectiveShortcut(for: "space.selectByNumber") == Shortcut("1", modifiers: [.control, .option]))
    }
}
