import AppKit
import Foundation
import Testing
@testable import CmuxNextActions

/// The `context_menus` export (plans/cmux-next/action-surfaces.json) is what
/// other clients (GPUI) build right-click menus from. Rendered with the
/// export's own rules (`context_menu_rules`), it must give exactly the menus
/// `ActionRegistry.makeContextMenu` builds: same rows, order, separators,
/// submenus, folders and choice lists, in a bare context and with every
/// context name true.
@MainActor @Suite struct ContextMenuExportParityTests {
    indirect enum Node: Equatable, CustomStringConvertible {
        case item(String)
        case separator
        case menu(String, [Node])

        var description: String {
            switch self {
            case .item(let title): title
            case .separator: "---"
            case .menu(let title, let children): "\(title) > [\(children.map(\.description).joined(separator: ", "))]"
            }
        }
    }

    static func live(_ menu: NSMenu) -> [Node] {
        menu.items.map { item in
            if item.isSeparatorItem { return .separator }
            if let submenu = item.submenu { return .menu(item.title, live(submenu)) }
            return .item(item.title)
        }
    }

    /// Renders exported entries the way `context_menu_rules` says.
    static func render(_ entries: [[String: Any]], registry: ActionRegistry, context: ActionContext) -> [Node] {
        func requires(_ row: [String: Any]) -> ActionContext {
            let names = ((row["visible_when"] as? [String: Any])?["requires"] as? [String]) ?? []
            return ActionContext.keyNames.filter { names.contains($0.1) }.reduce(into: ActionContext()) { $0.insert($1.0) }
        }
        func visible(_ row: [String: Any]) -> Bool {
            guard let when = row["visible_when"] as? [String: Any] else { return true }
            if (when["debug_only"] as? Bool) == true && !DevTools.isEnabled { return false }
            return context.isSuperset(of: requires(row))
        }
        func plain(_ title: String) -> String { title.hasSuffix("…") ? String(title.dropLast()) : title }
        var nodes: [Node] = []
        for row in entries.sorted(by: { ($0["order"] as? Int ?? 0) < ($1["order"] as? Int ?? 0) }) {
            let id = (row["id"] as? String).map(ActionID.init(rawValue:))
            switch row["kind"] as? String {
            case "separator":
                if let last = nodes.last, last != .separator { nodes.append(.separator) }
            case "action":
                guard visible(row), let id, let title = registry.title(for: id) else { continue }
                nodes.append(.item(title))
            case "choices":
                guard visible(row), let id, let title = registry.title(for: id),
                      let choices = row["choices"] as? [String: Any], let values = choices["values"] as? [[String: Any]] else { continue }
                var children = values.compactMap { $0["title"] as? String }.map(Node.item)
                if (choices["more_opens_palette"] as? Bool) == true { children += [.separator, .item(ActionSuggestionsStrings.more)] }
                nodes.append(.menu(plain(title), children))
            case "submenu":
                let children = render(row["children"] as? [[String: Any]] ?? [], registry: registry, context: context)
                guard visible(row), !children.isEmpty, let id, let title = registry.title(for: id) else { continue }
                nodes.append(.menu(plain(title), children))
            case "folder":
                let children = render(row["children"] as? [[String: Any]] ?? [], registry: registry, context: context)
                guard children.contains(where: { $0 != .separator }), let title = row["title"] as? String else { continue }
                nodes.append(.menu(title, children))
            default:
                Issue.record("unknown kind in \(row)")
            }
        }
        while nodes.last == .separator { nodes.removeLast() }
        return nodes
    }

    static func exportedMenus() throws -> [String: Any] {
        let text = ActionSurfaceExport.json(ActionCatalog.all, titles: try ActionSurfaceParityTests.titleCatalog())
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect((root["context_menu_rules"] as? [String])?.isEmpty == false)
        // The hand-built menus are a named known gap, never silently absent.
        let gap = try #require(root["context_menus_not_exported"] as? [[String: String]])
        #expect(!gap.isEmpty && gap.allSatisfy { $0["name"]?.isEmpty == false && $0["source"]?.isEmpty == false })
        return try #require(root["context_menus"] as? [String: Any])
    }

    /// F3 (2fa9520ccdf) gave menu rows a menu-only `label` ("Change Space
    /// Icon…" for Set Space Icon…) and exports it with the row, so the rules a
    /// client renders by must say the label replaces the action's title.
    @Test func theRulesSayARowsLabelReplacesItsTitle() {
        #expect(ContextMenuCatalog.exportRenderRules.contains { $0.contains("label") && $0.contains("instead of") })
    }

    @Test(arguments: [false, true])
    func exportRendersExactlyTheLiveMenus(everyContextName: Bool) throws {
        let registry = ActionRegistry.standard()
        // Bound actions only: a choices row needs a bound action.
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) { _ in } }
        let all = ActionContext.keyNames.reduce(into: ActionContext()) { $0.insert($1.0) }
        let extra: ActionContext = everyContextName ? all : []
        let menus = try Self.exportedMenus()
        var checked = 0
        for context in ActionMenuContext.allCases {
            let liveNodes = Self.live(registry.makeContextMenu(for: context, implied: extra))
            guard let menu = menus[context.rawValue] as? [String: Any] else {
                #expect(liveNodes.isEmpty, "\(context.rawValue) has a live menu but no export")
                continue
            }
            let implied = (menu["implied"] as? [String]) ?? []
            let impliedBits = ActionContext.keyNames.filter { implied.contains($0.1) }.reduce(into: ActionContext()) { $0.insert($1.0) }
            #expect(impliedBits == ActionRegistry.impliedContext(for: context), "\(context.rawValue) implied")
            let rendered = Self.render(menu["entries"] as? [[String: Any]] ?? [], registry: registry,
                                       context: registry.context.union(impliedBits).union(extra))
            #expect(rendered == liveNodes, "\(context.rawValue): export \(rendered) vs live \(liveNodes)")
            checked += 1
        }
        #expect(checked >= 10, "most menu contexts are exported")
    }

    /// Localizable choice titles carry their key and table (GPUI localizes them).
    @Test func choiceValuesNameTheirLocalizationKey() throws {
        func rows(_ entries: [[String: Any]]) -> [[String: Any]] {
            entries.flatMap { [$0] + rows($0["children"] as? [[String: Any]] ?? []) }
        }
        let page = try #require(try Self.exportedMenus()["browserPage"] as? [String: Any])
        let theme = try #require(rows(page["entries"] as? [[String: Any]] ?? []).first { ($0["id"] as? String) == "browserTheme" })
        let values = try #require((theme["choices"] as? [String: Any])?["values"] as? [[String: Any]])
        #expect(values.map { $0["value"] as? String } == ["system", "light", "dark"])
        #expect(values.allSatisfy { ($0["title_key"] as? String)?.hasPrefix("argument.value.") == true && ($0["title_table"] as? String) == "Localizable" })
    }
}
