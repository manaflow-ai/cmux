import Foundation

/// One `type: "text"` action as the Snippets context menu sees it.
struct CmuxSnippetMenuEntry: Sendable, Hashable {
    var actionID: String
    var title: String
    var category: String?
    var payload: CmuxTextActionPayload
}

struct CmuxSnippetMenuItem: Sendable, Hashable {
    var actionID: String
    var title: String
    var payload: CmuxTextActionPayload
}

struct CmuxSnippetMenuCategory: Sendable, Hashable {
    var name: String
    var items: [CmuxSnippetMenuItem]
}

/// Category tree behind the terminal right-click "Snippets" submenu.
/// Uncategorised snippets come first, then one sub-submenu per category.
/// Everything is sorted so the menu is stable across config reloads.
struct CmuxSnippetMenuModel: Sendable, Hashable {
    var uncategorized: [CmuxSnippetMenuItem]
    var categories: [CmuxSnippetMenuCategory]

    var isEmpty: Bool {
        uncategorized.isEmpty && categories.isEmpty
    }

    static func build(from entries: [CmuxSnippetMenuEntry]) -> CmuxSnippetMenuModel {
        var uncategorized: [CmuxSnippetMenuItem] = []
        var categoryOrder: [String] = []          // canonical (lowercased) keys, first-seen order
        var categoryNames: [String: String] = [:] // canonical key -> first spelling
        var categoryItems: [String: [CmuxSnippetMenuItem]] = [:]

        for entry in entries {
            let item = CmuxSnippetMenuItem(
                actionID: entry.actionID,
                title: entry.title,
                payload: entry.payload
            )
            let trimmed = entry.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                uncategorized.append(item)
                continue
            }
            let key = trimmed.lowercased()
            if categoryNames[key] == nil {
                categoryNames[key] = trimmed
                categoryOrder.append(key)
            }
            categoryItems[key, default: []].append(item)
        }

        let categories = categoryOrder
            .map { key in
                CmuxSnippetMenuCategory(
                    name: categoryNames[key] ?? key,
                    items: (categoryItems[key] ?? []).sorted(by: Self.byTitle)
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return CmuxSnippetMenuModel(
            uncategorized: uncategorized.sorted(by: Self.byTitle),
            categories: categories
        )
    }

    private static func byTitle(_ lhs: CmuxSnippetMenuItem, _ rhs: CmuxSnippetMenuItem) -> Bool {
        lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}
