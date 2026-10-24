import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// A conflict badge on the Keyboard Shortcuts page counts only bindings where one never runs
/// because of the other (dogfood run 7, cx-gesnr; Lucas 2026-10-24). The later entry wins, so
/// the pair conflicts when the earlier one's `when` holding means the later one's holds. Cmd-0 is
/// Actual Size in each surface (the browser, an agent chat, markdown, the code editor, the
/// canvas) and the terminal's font size: every one still runs in its own context, so none of
/// them conflicts. A user's Cmd-0 with no condition takes the key from every one of them.
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

    @Test func cmdZeroInEachSurfaceConflictsWithNothing() {
        let rows = Self.rows(ActionRegistry.standard())
        for command in Self.actualSizes {
            #expect(Self.conflicts(of: command, in: rows) == [], "\(command) counted conflicts")
        }
    }

    /// A later binding takes an earlier one's keys when the earlier `when` holding means the later
    /// one's holds, read over `&&` and `||` (code review: an `||` that covers it was missed).
    @Test func implicationReadsAndAndOr() throws {
        let browser = try WhenClause.parse("browserFocused")
        #expect(WhenClause.implies(browser, try WhenClause.parse("browserFocused || terminalFocused")))
        #expect(!WhenClause.implies(try WhenClause.parse("browserFocused || terminalFocused"), browser))
        #expect(WhenClause.implies(try WhenClause.parse("browserFocused && !dialogOpen"), browser))
        #expect(!WhenClause.implies(browser, try WhenClause.parse("browserFocused && !dialogOpen")))
        #expect(WhenClause.implies(try WhenClause.parse("browserFocused || markdownFocused"),
                                   try WhenClause.parse("markdownFocused || browserFocused")))
        #expect(WhenClause.implies(browser, nil))
        #expect(!WhenClause.implies(nil, browser))
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
            KeybindingReports.conflicts(["command": "newWindow", "key": "cmd+0"], registry: before), "bindings") else {
            Issue.record("no conflicts reply")
            return
        }
        #expect(Set(taken.compactMap { Self.field($0, "command")?.stringValue }).isSuperset(of: Self.actualSizes))
        guard case .array(let none)? = Self.field(KeybindingReports.conflicts(
            ["command": "browserZoomReset", "key": "cmd+0", "when": "browserFocused"], registry: before), "bindings") else {
            Issue.record("no conflicts reply")
            return
        }
        #expect(none.isEmpty, "Actual Size in the browser takes Cmd-0 from \(none)")
    }
}
