import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// A conflict badge on the Keyboard Shortcuts page counts only bindings that can compete
/// (dogfood run 7, cx-gesnr). The keyboard has one focused surface: a terminal, a browser page,
/// an agent chat, or one internal page (markdown, the diff viewer, the code editor), so their
/// focus keys never hold together (`KeyRouter.keyContext`). The address bar is inside the browser:
/// `omnibarFocused` holds with `browserFocused`. Cmd-0's Actual Size in the browser showed six
/// conflicts, four of them focus keys it never holds with.
@MainActor @Suite struct KeybindingsFocusConflictTests {
    @Test func browserActualSizeConflictsOnlyWithBindingsThatCanHoldWithBrowserFocus() {
        guard case .object(let page) = KeybindingReports.pageList([:], registry: ActionRegistry.standard()),
              case .array(let rows)? = page["bindings"] else {
            Issue.record("no bindings")
            return
        }
        func field(_ row: JSONValue, _ key: String) -> JSONValue? {
            guard case .object(let object) = row else { return nil }
            return object[key]
        }
        let commands = Dictionary(rows.compactMap { row -> (Int, String)? in
            guard case .number(let id)? = field(row, "id"), let command = field(row, "command")?.stringValue else { return nil }
            return (Int(id), command)
        }, uniquingKeysWith: { first, _ in first })
        guard let browser = rows.first(where: { field($0, "command")?.stringValue == "browserZoomReset" }),
              case .array(let ids)? = field(browser, "conflicts") else {
            Issue.record("browserZoomReset is not listed")
            return
        }
        let conflicts = Set(ids.compactMap { id -> String? in
            guard case .number(let value) = id else { return nil }
            return commands[Int(value)]
        })
        // Other focused surfaces: never at the same time as the browser.
        for other in ["agentPaneZoomReset", "markdownZoomReset", "fileEditorZoomReset", "terminal.resetFontSize"] {
            #expect(!conflicts.contains(other), "\(other) counted as a conflict of the browser's Actual Size")
        }
        // A binding with no focus key, and the canvas layout (not a focus), can hold with it.
        #expect(conflicts.contains("resetWorkspaceTerminalFontSize"))
        #expect(conflicts.contains("canvasZoomReset"))
    }
}
