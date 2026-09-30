import Foundation

/// One `type: "text"` action as the Snippets context menu sees it.
public struct CmuxSnippetMenuEntry: Sendable, Hashable {
    public var actionID: String
    public var title: String
    public var category: String?
    public var payload: CmuxTextActionPayload

    public init(actionID: String, title: String, category: String?, payload: CmuxTextActionPayload) {
        self.actionID = actionID
        self.title = title
        self.category = category
        self.payload = payload
    }
}

public struct CmuxSnippetMenuItem: Sendable, Hashable {
    public var actionID: String
    public var title: String
    public var payload: CmuxTextActionPayload

    public init(actionID: String, title: String, payload: CmuxTextActionPayload) {
        self.actionID = actionID
        self.title = title
        self.payload = payload
    }
}

public struct CmuxSnippetMenuCategory: Sendable, Hashable {
    public var name: String
    public var items: [CmuxSnippetMenuItem]

    public init(name: String, items: [CmuxSnippetMenuItem]) {
        self.name = name
        self.items = items
    }
}

/// Category tree behind the terminal right-click "Snippets" submenu.
/// Uncategorised snippets come first, then one sub-submenu per category.
/// Everything is sorted so the menu is stable across config reloads.
public struct CmuxSnippetMenuModel: Sendable, Hashable {
    public var uncategorized: [CmuxSnippetMenuItem]
    public var categories: [CmuxSnippetMenuCategory]

    public init(uncategorized: [CmuxSnippetMenuItem], categories: [CmuxSnippetMenuCategory]) {
        self.uncategorized = uncategorized
        self.categories = categories
    }

    /// True when there is nothing to show, so callers can omit the submenu.
    public var isEmpty: Bool {
        uncategorized.isEmpty && categories.isEmpty
    }

    /// Groups entries by trimmed, case-insensitive category (first spelling
    /// wins as the display name) and sorts categories and items by title.
    public static func build(from entries: [CmuxSnippetMenuEntry]) -> CmuxSnippetMenuModel {
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

    /// Locale-aware title ordering shared by every level of the menu.
    private static func byTitle(_ lhs: CmuxSnippetMenuItem, _ rhs: CmuxSnippetMenuItem) -> Bool {
        lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}
