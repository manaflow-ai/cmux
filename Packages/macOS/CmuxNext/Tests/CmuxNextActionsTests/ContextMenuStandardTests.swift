import AppKit
@testable import CmuxNextActions
import Testing

/// Every right-click menu reads like a standard macOS menu (Lawrence 2026-10-22: "fix all context
/// menus such that it is very standard, need better icons for all too"): each row's icon is a real
/// SF Symbol drawn as an outline, as Finder's and Safari's menus draw theirs, no two rows of one
/// menu or submenu share an icon, the tab bar's + lists the tab kinds first, and a row that
/// deletes ends its menu. Color swatches (Grey, Blue, …) are filled dots on purpose and exempt.
@MainActor
struct ContextMenuStandardTests {
    private let menus = ContextMenuCatalog.shared
    private let byID = Dictionary(ActionCatalog.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    private func isSwatch(_ id: ActionID) -> Bool { id.rawValue.contains(".color.") }

    /// The rows of each menu level (the menu, then every submenu and folder), with the path to it.
    private func levels(_ entries: [ContextMenuEntry], path: String) -> [(path: String, ids: [ActionID])] {
        var ids: [ActionID] = []
        var nested: [(path: String, ids: [ActionID])] = []
        for entry in entries {
            switch entry {
            case .action(let id), .choices(let id): ids.append(id)
            case .separator: break
            case .submenu(let id, let children):
                ids.append(id)
                nested += levels(children, path: "\(path) › \(id.rawValue)")
            case .folder(let folder, let children):
                nested += levels(children, path: "\(path) › \(folder.title)")
            case .group(let group, let children):
                nested += levels(children, path: "\(path) › \(group.title)")
            }
        }
        return [(path, ids)] + nested
    }

    private var allLevels: [(path: String, ids: [ActionID])] {
        ActionMenuContext.allCases.flatMap { levels(menus.entries(for: $0), path: "\($0)") }
    }

    /// The icon the registry draws for a row (`ActionRegistry.menuIcon`): nil means a blank icon column.
    @Test func everyRowDrawsAnSFSymbol() {
        for (path, ids) in allLevels {
            for id in ids where !isSwatch(id) {
                let symbol = byID[id]?.symbol ?? "command"
                #expect(ActionRegistry.menuIcon(symbol) != nil, "\(path): \(id) has no icon (\(symbol))")
            }
        }
    }

    @Test func iconsAreOutlinesNotFills() {
        for (path, ids) in allLevels {
            for id in ids where !isSwatch(id) {
                guard let symbol = byID[id]?.symbol else { continue }
                #expect(!symbol.split(separator: ".").contains("fill"), "\(path): \(id) draws a filled icon (\(symbol))")
            }
        }
    }

    @Test func noTwoRowsOfOneMenuShareAnIcon() {
        for (path, ids) in allLevels {
            var seen: [String: ActionID] = [:]
            for id in ids where !isSwatch(id) {
                guard let symbol = byID[id]?.symbol, symbol != "command" else { continue }
                if let first = seen[symbol] {
                    Issue.record("\(path): \(first) and \(id) both draw \(symbol)")
                } else {
                    seen[symbol] = id
                }
            }
        }
    }

    /// The tab bar's +: the kinds of tab (Mac Screen too), then the ways to pick one. The catalog
    /// also places Inspect Element (#24707) last, in its own group; the app leaves that row out
    /// until Debug Settings' UI pointer inspector is on (PointerInspectorMenuGateTests).
    @Test func newTabMenuListsTheKindsFirst() {
        let entries = menus.entries(for: .newTab)
        let ids = entries.map { entry -> String in
            switch entry {
            case .action(let id): id.rawValue
            case .separator: "—"
            default: "?"
            }
        }
        #expect(ids == ["newSurface", "openBrowser.chromium", "palette.newAgentChat", "macScreen.open", "—", "browserProfile.newTab", "newTab.page",
                        "—", "agentPane.togglePointerInspector"])
    }

    /// Delete, Remove and Forget rows (a trash icon) end their menu, after a separator.
    @Test func aDeleteRowEndsItsMenu() {
        for context in ActionMenuContext.allCases {
            let entries = menus.entries(for: context)
            for (index, entry) in entries.enumerated() {
                guard case .action(let id) = entry, byID[id]?.symbol == "trash" else { continue }
                #expect(index == entries.count - 1, "\(context): \(id) is not the menu's last row")
                if index > 0, case .separator = entries[index - 1] {} else {
                    Issue.record("\(context): \(id) has no separator above it")
                }
            }
        }
    }
}
