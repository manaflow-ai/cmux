public import Foundation

/// A list page: the root command list or a nested list.
public struct PalettePageSpec {
    public let id: String
    /// The palette scope this page shows (plans/cmux-next/palette-scopes.md):
    /// `.root` for the full palette, a graph scope such as `tabs`, or nil
    /// for a page of its own (argument picker, history list), which is
    /// scope `page:<id>`.
    public var scope: PaletteScopeID?
    public var title: String
    public var placeholder: String
    public var symbol: String
    public var providers: [any PaletteProvider]
    /// Show a Recent section for an empty query.
    public var showsRecent: Bool
    /// The query the page opens with (an action run with a `query`).
    public var initialQuery: String
    /// Cmd-W belongs to the page's rows: it never reaches the main menu
    /// (Close Tab on the tab behind the palette), also with no row or the
    /// Actions menu open.
    public var ownsCloseKey: Bool
    /// Sections keep their `order` for a typed query too, instead of
    /// following their best match (Search Tabs keeps closed tabs below
    /// open ones).
    public var keepsSectionOrder: Bool
    /// A typed query ranks rows whose title starts with it first, in the
    /// providers' order (the picker's Finder order: `c2` before `c10`), then
    /// the other matches by score.
    public var ranksPrefixFirst: Bool
    /// The row selected when the page shows its empty-query list, clamped
    /// to the rows (Search Tabs selects the tab used before the current
    /// one, so Return switches back).
    public var emptyQuerySelection: Int
    /// The highlighted row (hover, else selection) changed to this item.
    public var onHighlight: (@MainActor (PaletteItem?) -> Void)?
    /// The page was left (popped, replaced or the palette closed) without
    /// running one of its closing commands.
    public var onLeave: (@MainActor () -> Void)?
    /// Like `onLeave`, but also when no row was ever highlighted (an empty
    /// folder): a page that waits for a choice hears every way out once.
    public var onCancel: (@MainActor () -> Void)?
    /// A tree the page walks in place (``PaletteHierarchy``).
    public var hierarchy: PaletteHierarchy?
    /// The row to select for an empty query, by id, once it is listed (the
    /// folder a step up came from). Wins over `emptyQuerySelection`.
    public var emptyQuerySelectionID: String?
    /// Rows made from the query itself, shown first (a save picker's "Save
    /// “name”" row): the query is an answer here, not only a search.
    public var queryItems: (@MainActor (String) -> [PaletteItem])?
    /// False: the query never filters the providers' rows (a save picker's
    /// folders stay listed while the name is typed).
    public var filtersByQuery: Bool
    /// A small line under the field (the picker's "Type to filter, or start
    /// with / to type a path").
    public var hint: String?
    /// The footer's title as clickable segments (the picker's path); empty
    /// shows `title`.
    public var crumbs: [PaletteCrumb]
    /// UTF-16 length of the `initialQuery` prefix selected when the page
    /// opens (a file name without its extension); nil puts the caret at
    /// the end.
    public var initialQuerySelection: Int?

    public init(
        id: String,
        title: String,
        placeholder: String,
        symbol: String = "command",
        providers: [any PaletteProvider],
        showsRecent: Bool = false,
        initialQuery: String = "",
        ownsCloseKey: Bool = false,
        keepsSectionOrder: Bool = false,
        ranksPrefixFirst: Bool = false,
        emptyQuerySelection: Int = 0,
        onHighlight: (@MainActor (PaletteItem?) -> Void)? = nil,
        onLeave: (@MainActor () -> Void)? = nil,
        onCancel: (@MainActor () -> Void)? = nil,
        hierarchy: PaletteHierarchy? = nil,
        emptyQuerySelectionID: String? = nil,
        queryItems: (@MainActor (String) -> [PaletteItem])? = nil,
        filtersByQuery: Bool = true,
        initialQuerySelection: Int? = nil,
        hint: String? = nil,
        crumbs: [PaletteCrumb] = [],
        scope: PaletteScopeID? = nil
    ) {
        self.id = id
        self.scope = scope
        self.title = title
        self.placeholder = placeholder
        self.symbol = symbol
        self.providers = providers
        self.showsRecent = showsRecent
        self.initialQuery = initialQuery
        self.ownsCloseKey = ownsCloseKey
        self.keepsSectionOrder = keepsSectionOrder
        self.ranksPrefixFirst = ranksPrefixFirst
        self.emptyQuerySelection = emptyQuerySelection
        self.onHighlight = onHighlight
        self.onLeave = onLeave
        self.onCancel = onCancel
        self.hierarchy = hierarchy
        self.emptyQuerySelectionID = emptyQuerySelectionID
        self.queryItems = queryItems
        self.filtersByQuery = filtersByQuery
        self.initialQuerySelection = initialQuerySelection
        self.hint = hint
        self.crumbs = crumbs
    }
}

/// One clickable segment of a page's footer title: a click shows `page()`
/// in the current page's place (``PaletteModel/replaceCurrentPage(with:)``).
public struct PaletteCrumb {
    public var title: String
    public var page: @MainActor () -> PalettePageSpec?

    public init(title: String, page: @escaping @MainActor () -> PalettePageSpec?) {
        self.title = title
        self.page = page
    }
}

extension PalettePageSpec {
    /// The scope id the navigation stack uses for this page.
    var scopeID: PaletteScopeID { scope ?? PaletteScopeID("page:\(id)") }
}

/// An inline text entry page, used by argument-taking actions.
public struct PaletteTextInputSpec {
    public let id: String
    public var title: String
    public var placeholder: String
    public var symbol: String
    public var initialText: String
    /// Return on the untouched `initialText` closes without running: the
    /// initial text is a snapshot (a rename's current name), so committing
    /// it could revert a rename made meanwhile.
    public var skipsUnchangedText: Bool
    /// Row title for the current text, such as "Rename to “api”".
    public var submitTitle: @MainActor (String) -> String
    public var isValid: @MainActor (String) -> Bool
    public var submit: @MainActor (String) -> Void
    /// What Return does with the text when it is not the last step (an
    /// argument chain pushes the next page). Nil means close and `submit`.
    public var next: (@MainActor (String) -> PaletteEffect)?

    public init(
        id: String,
        title: String,
        placeholder: String,
        symbol: String = "pencil",
        initialText: String = "",
        skipsUnchangedText: Bool = false,
        submitTitle: @escaping @MainActor (String) -> String,
        isValid: @escaping @MainActor (String) -> Bool = { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
        next: (@MainActor (String) -> PaletteEffect)? = nil,
        submit: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.id = id
        self.title = title
        self.placeholder = placeholder
        self.symbol = symbol
        self.initialText = initialText
        self.skipsUnchangedText = skipsUnchangedText
        self.submitTitle = submitTitle
        self.isValid = isValid
        self.submit = submit
        self.next = next
    }
}
