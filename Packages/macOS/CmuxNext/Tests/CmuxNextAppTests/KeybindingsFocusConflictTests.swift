import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// A conflict on the Keyboard Shortcuts page is two actions on the same keys whose `when` can
/// hold at the same time, one of them made by someone (dogfood run 7, cx-gesnr; Lucas
/// 2026-10-24): where both hold, the later one takes the key. Shipped defaults share keys by
/// design (Cmd-0 is Actual Size in each surface, the Chrome tab keys): an untouched table shows
/// none. A user's browser-only Cmd-T still takes New Tab's Cmd-T in the browser: a conflict.
@MainActor @Suite struct KeybindingsFocusConflictTests {
    static func rows(_ registry: ActionRegistry) -> [JSONValue] {
        guard case .object(let page) = KeybindingReports.pageList([:], registry: registry),
              case .array(let rows)? = page["bindings"] else { return [] }
        return rows
    }

    static func field(_ row: JSONValue, _ key: String) -> JSONValue? {
        guard case .object(let object) = row else { return nil }
        return object[key]
    }

    /// The commands of `command`'s row's conflicts.
    static func conflicts(of command: String, in rows: [JSONValue]) -> Set<String>? {
        let commands = Dictionary(rows.compactMap { row -> (Int, String)? in
            guard case .number(let id)? = field(row, "id"), let command = field(row, "command")?.stringValue else { return nil }
            return (Int(id), command)
        }, uniquingKeysWith: { first, _ in first })
        guard let row = rows.first(where: { field($0, "command")?.stringValue == command }),
              case .array(let ids)? = field(row, "conflicts") else { return nil }
        return Set(ids.compactMap { id -> String? in
            guard case .number(let value) = id else { return nil }
            return commands[Int(value)]
        })
    }

    static let actualSizes = ["browserZoomReset", "agentPaneZoomReset", "markdownZoomReset", "fileEditorZoomReset",
                              "canvasZoomReset", "terminal.resetFontSize", "resetWorkspaceTerminalFontSize"]

    /// Shipped defaults share keys by design (the Chrome tab keys and Cmd-1…9, Home's chat keys,
    /// the palette's Cmd-W): no badge on a table nobody changed.
    @Test func shippedDefaultsNeverConflict() {
        for row in Self.rows(ActionRegistry.standard()) {
            guard case .array(let ids)? = Self.field(row, "conflicts") else { continue }
            #expect(ids.isEmpty, "\(Self.field(row, "command")?.stringValue ?? "?") conflicts on a default table")
        }
    }

    @Test func cmdZeroInEachSurfaceConflictsWithNothing() {
        let rows = Self.rows(ActionRegistry.standard())
        for command in Self.actualSizes {
            #expect(Self.conflicts(of: command, in: rows) == [], "\(command) counted conflicts")
        }
    }

    /// One action on the same keys twice (its cmux default and its Ghostty default keybind, as
    /// Focus Left on Cmd-Opt-Left) runs either way: never its own conflict.
    @Test func noActionConflictsWithItself() {
        let registry = ActionRegistry.standard()
        // Ghostty's own split keys, routed as Ghostty defaults (as the app loads them).
        KeyBindingLoader(registry).loadGhostty([
            KeyBinding(keys: [Shortcut("d", modifiers: [.command, .shift])], command: "splitDown", source: .ghosttyFallback),
            KeyBinding(keys: [Shortcut(Shortcut.leftArrowKey, modifiers: [.command, .option])], command: "focusLeft",
                       source: .ghosttyFallback),
        ])
        let rows = Self.rows(registry)
        for row in rows {
            guard let command = Self.field(row, "command")?.stringValue,
                  let conflicts = Self.conflicts(of: command, in: [row] + rows.filter { $0 != row }) else { continue }
            #expect(!conflicts.contains(command), "\(command) conflicts with itself")
        }
    }

    @Test func aUsersCmdZeroWithNoConditionTakesItFromEverySurface() {
        let registry = ActionRegistry.standard()
        registry.setShortcutOverride(Shortcut("0", modifiers: .command), for: "newWindow")
        let rows = Self.rows(registry)
        #expect(Self.conflicts(of: "newWindow", in: rows)?.isSuperset(of: Self.actualSizes) == true)
        #expect(Self.conflicts(of: "browserZoomReset", in: rows) == ["newWindow"])
        // Asked before the save: the same answer from `cmux.keybindings.conflicts`.
        let before = ActionRegistry.standard()
        guard case .array(let taken)? = Self.field(
            KeybindingReports.conflicts(["command": "newWindow", "key": "cmd+0"], when: nil, registry: before), "bindings") else {
            Issue.record("no conflicts reply")
            return
        }
        let takenCommands = Set(taken.compactMap { Self.field($0, "command")?.stringValue })
        #expect(takenCommands.isSuperset(of: Self.actualSizes))
        // A global Cmd-0 holds wherever each of them runs: Overwrite takes it from all of them.
        #expect(taken.allSatisfy { Self.field($0, "takesAll") == .bool(true) })
    }

    /// Actual Size runs in a focused browser; on Cmd-T it would take New Tab's key there, so it
    /// conflicts, although New Tab still runs everywhere else (Lucas 2026-10-24).
    @Test func aBrowserOnlyCmdTTakesNewTabsKeyInTheBrowser() throws {
        let registry = ActionRegistry.standard()
        guard case .array(let taken)? = Self.field(KeybindingReports.conflicts(
            ["command": "browserZoomReset", "key": "cmd+t"], when: try WhenClause.parse("browserFocused"),
            registry: registry), "bindings") else {
            Issue.record("no conflicts reply")
            return
        }
        let commands = Set(taken.compactMap { Self.field($0, "command")?.stringValue })
        #expect(!commands.isDisjoint(with: ["newSurface", "newTab.default", "newTab"]), "Cmd-T takes: \(commands)")
        // It takes the key in the browser only: New Tab keeps Cmd-T everywhere else, so
        // Overwrite leaves its entry (Lucas 2026-10-25: Overwrite had unbound New Tab everywhere).
        #expect(taken.allSatisfy { Self.field($0, "takesAll") == .bool(false) })
        // A focused terminal and a focused browser never hold together: no conflict there.
        guard case .array(let none)? = Self.field(KeybindingReports.conflicts(
            ["command": "terminal.resetFontSize", "key": "cmd+0"], when: try WhenClause.parse("terminalFocused"),
            registry: registry), "bindings") else {
            Issue.record("no conflicts reply")
            return
        }
        let noneCommands = none.compactMap { Self.field($0, "command")?.stringValue }
        #expect(!noneCommands.contains("browserZoomReset"))
    }

    /// Actual Size moved to Cmd-F and back to Cmd-0 is its shipped default again (the table lists
    /// it as one): the check before the save asked about Reset Workspace Font Size, Reset Font
    /// Size and the canvas's Actual Size, the other surfaces' default Cmd-0 (Lucas 2026-10-24).
    static func writes() -> (AppServices, KeybindingPageWrites) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let url = FileManager.default.temporaryDirectory.appending(path: "cnc-kb-restore-\(UUID().uuidString).json")
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        return (services, KeybindingPageWrites(registry: services.registry, settings: settings, file: services.keybindingsFile))
    }

    @Test func actualSizeBackOnItsDefaultCmdZeroConflictsWithNothing() throws {
        let (services, writes) = Self.writes()
        services.registry.setShortcutOverride(Shortcut("f", modifiers: .command), for: "browserZoomReset")
        let moved = try #require(RegistryKeyBindings(services.registry).table.entries.last { $0.command == "browserZoomReset" })
        let when: JSONValue = moved.when.map { .string($0.text) } ?? .null
        let back: [String: JSONValue] = ["command": "browserZoomReset", "key": "cmd+0", "when": when,
                                         "replaces": ["key": "cmd+f", "when": when]]
        #expect(writes.restoresDefault(back))
        #expect(!writes.restoresDefault(back.merging(["key": "cmd+9"]) { $1 }))
        guard case .array(let taken)? = Self.field(KeybindingReports.conflicts(
            back, when: writes.savedWhen(back), asDefault: writes.restoresDefault(back), registry: services.registry), "bindings")
        else {
            Issue.record("no conflicts reply")
            return
        }
        #expect(taken.isEmpty, "Cmd-0 back on Actual Size takes: \(taken.compactMap { Self.field($0, "command")?.stringValue })")
    }

    /// Select Tab 1…9 moved to Cmd-Opt and back to its Ctrl digits is its shipped family again
    /// (`moveFamily` drops the override): Home's Ctrl-1…9 Select Conversation shares those keys
    /// by design, no question (the restore-every-default sweep on the keyclick build, 2026-10-24).
    @Test func aNumberedFamilyBackOnItsDefaultModifiersConflictsWithNothing() throws {
        let (services, writes) = Self.writes()
        let shipped = try #require(services.registry.descriptor(for: "selectSurfaceByNumber")?.defaultShortcut)
        services.registry.setShortcutOverride(Shortcut("1", modifiers: [.command, .option]), for: "selectSurfaceByNumber")
        let moved = try #require(RegistryKeyBindings(services.registry).table.entries.last {
            $0.command == "selectSurfaceByNumber" && $0.argument == "3"
        })
        let when: JSONValue = moved.when.map { .string($0.text) } ?? .null
        let back: [String: JSONValue] = [
            "command": "selectSurfaceByNumber", "key": .string(KeybindingReports.text([Shortcut("3", modifiers: shipped.modifiers)])),
            "when": when, "replaces": ["key": .string(KeybindingReports.text(moved.keys)), "when": when],
        ]
        #expect(writes.restoresDefault(back))
        guard case .array(let taken)? = Self.field(KeybindingReports.conflicts(
            back, when: writes.savedWhen(back), asDefault: writes.restoresDefault(back), registry: services.registry), "bindings")
        else {
            Issue.record("no conflicts reply")
            return
        }
        #expect(taken.isEmpty, "Select Tab back on its digits takes: \(taken.compactMap { Self.field($0, "command")?.stringValue })")
    }

    /// A "Not Set" numbered family moves to the recorded modifiers on its digits: a letter is
    /// refused before the save, so no question offers to take that letter from another action
    /// (review 2026-10-26: Overwrite removed a key the family never took).
    @Test func anUnsetFamilyTakesOnlyADigit() {
        let (services, writes) = Self.writes()
        services.registry.setShortcutOverride(nil, for: "selectSurfaceByNumber")
        let letter: [String: JSONValue] = ["command": "selectSurfaceByNumber", "key": "ctrl+opt+t", "when": .null]
        #expect(writes.refusal(letter)?.message == KeybindingStrings.familyNeedsDigit)
        #expect(!writes.restoresDefault(letter))
        let digit: [String: JSONValue] = ["command": "selectSurfaceByNumber", "key": "ctrl+opt+3", "when": .null]
        #expect(writes.refusal(digit)?.message != KeybindingStrings.familyNeedsDigit)
    }

    /// Keys that give an action its default back are checked with the shipped entry's `when`
    /// (with the keys it yields to a terminal program or the code editor), not only its
    /// `requires`: a terminal-only entry on the same keys is not taken everywhere.
    @Test func aRestoredDefaultIsCheckedWithItsShippedWhen() throws {
        let (services, writes) = Self.writes()
        let id: ActionID = "groupSelectedWorkspaces"
        let shipped = try #require(services.registry.descriptor(for: id)?.defaultShortcut)
        let entry = try #require(RegistryKeyBindings(services.registry).table.entries.last { $0.command == id && $0.keys == [shipped] })
        services.registry.setShortcutOverride(Shortcut("9", modifiers: [.command, .option, .control]), for: id)
        let moved = try #require(RegistryKeyBindings(services.registry).table.entries.last { $0.command == id })
        let when: JSONValue = moved.when.map { .string($0.text) } ?? .null
        let back: [String: JSONValue] = ["command": .string(id.rawValue), "key": .string(KeybindingReports.text([shipped])),
                                         "when": when, "replaces": ["key": .string(KeybindingReports.text(moved.keys)), "when": when]]
        #expect(writes.restoresDefault(back))
        #expect(writes.savedWhen(back) == entry.when)
        #expect(writes.sameScopeOwners(back).isEmpty)
        // Another action's user entry on those keys sits above the restored default and would keep
        // them where both hold: Overwrite must take them from it (review 2026-10-27).
        services.registry.setShortcutOverride(shipped, for: "newWindow")
        guard case .array(let taken)? = Self.field(KeybindingReports.conflicts(
            back, when: writes.savedWhen(back), asDefault: writes.restoresDefault(back), registry: services.registry), "bindings")
        else {
            Issue.record("no conflicts reply")
            return
        }
        let newWindow = taken.filter { Self.field($0, "command")?.stringValue == "newWindow" }
        #expect(!newWindow.isEmpty)
        #expect(newWindow.allSatisfy { Self.field($0, "takesAll") == .bool(true) })
    }
}
