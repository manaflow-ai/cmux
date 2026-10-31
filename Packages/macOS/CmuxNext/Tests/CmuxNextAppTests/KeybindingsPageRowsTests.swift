import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// The Keyboard Shortcuts page lists each binding once (dogfood run 7). The
/// table once held the catalog's Cmd-1…9 Select Workspace and Ctrl-Cmd-] / [
/// sidebar keys twice. The page listed both: Next Sidebar Item showed
/// twice, every copy counted the other as a conflict, and the two rows had
/// one identity, so the page's list piled up stale Select Workspace rows as
/// the search changed.
@MainActor @Suite struct KeybindingsPageRowsTests {
    /// A row's identity on the page (`identity` in webviews/src/pages/keybindings/model.ts).
    static func identity(_ row: JSONValue) -> String? {
        guard case .object(let object) = row else { return nil }
        let source = object["removed"] != nil ? "removed" : object["source"]?.stringValue ?? ""
        return [source, object["command"]?.stringValue ?? "", object["key"]?.stringValue ?? "",
                object["when"]?.stringValue ?? ""].joined(separator: "|")
    }

    static func rows(_ registry: ActionRegistry) -> [JSONValue] {
        guard case .object(let page) = KeybindingReports.pageList([:], registry: registry),
              case .array(let rows)? = page["bindings"] else { return [] }
        return rows
    }

    @Test func everyBindingIsOneRowAndNoRowConflictsWithItself() {
        let registry = ActionRegistry.standard()
        let rows = Self.rows(registry)
        var count: [String: Int] = [:]
        for row in rows { if let id = Self.identity(row) { count[id, default: 0] += 1 } }
        let repeated = count.filter { $0.value > 1 }.map(\.key).filter {
            $0.contains("|selectWorkspaceByNumber|") || $0.contains("|nextSidebarTab|") || $0.contains("|prevSidebarTab|")
        }.sorted()
        let workspace3 = rows.filter { Self.identity($0) == "default|selectWorkspaceByNumber|cmd+3|" }
        #expect(repeated.isEmpty, "rows listed more than once: \(repeated)")
        #expect(workspace3.count == 1, "Select Workspace 3 on cmd+3: \(workspace3.count) rows")
    }

    /// Remove on an action's only key unbinds it in cmux.json (`KeybindingPageWrites.remove`).
    /// The table then has no entry for it, and the page dropped the action: it could not get a
    /// key again from the page. It is one `unset` row with no keys until Reset or a new key.
    @Test func anActionWhoseKeysWereRemovedStaysAsOneUnsetRow() {
        let registry = ActionRegistry.standard()
        let id: ActionID = "bookmark.toggleBar"
        let rowsOfAction = {
            Self.rows(registry).compactMap { row -> [String: JSONValue]? in
                guard case .object(let object) = row, object["command"]?.stringValue == id.rawValue else { return nil }
                return object
            }
        }
        #expect(!rowsOfAction().isEmpty && rowsOfAction().allSatisfy { $0["unset"] == nil })

        registry.setShortcutOverride(nil, for: id)
        let unset = rowsOfAction()
        #expect(unset.count == 1, "rows of an unbound action: \(unset)")
        #expect(unset.first?["unset"] == .bool(true))
        #expect(unset.first?["key"]?.stringValue == "")
        #expect(unset.first?["source"]?.stringValue == "user")

        registry.removeShortcutOverride(for: id)
        #expect(!rowsOfAction().isEmpty && rowsOfAction().allSatisfy { $0["unset"] == nil })
    }
}
