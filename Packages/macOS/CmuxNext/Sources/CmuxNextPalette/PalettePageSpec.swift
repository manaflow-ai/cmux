public import Foundation

/// A list page: the root command list or a nested list.
public struct PalettePageSpec {
    public let id: String
    public var title: String
    public var placeholder: String
    public var symbol: String
    public var providers: [any PaletteProvider]
    /// Show a Recent section for an empty query.
    public var showsRecent: Bool
    /// The query the page opens with (an action run with a `query`).
    public var initialQuery: String
    /// Sections keep their `order` for a typed query too, instead of
    /// following their best match (Search Tabs keeps closed tabs below
    /// open ones).
    public var keepsSectionOrder: Bool
    /// The row selected when the page shows its empty-query list, clamped
    /// to the rows (Search Tabs selects the tab used before the current
    /// one, so Return switches back).
    public var emptyQuerySelection: Int
    /// The highlighted row (hover, else selection) changed to this item.
    public var onHighlight: (@MainActor (PaletteItem?) -> Void)?
    /// The page was left (popped, replaced or the palette closed) without
    /// running one of its closing commands.
    public var onLeave: (@MainActor () -> Void)?

    public init(
        id: String,
        title: String,
        placeholder: String,
        symbol: String = "command",
        providers: [any PaletteProvider],
        showsRecent: Bool = false,
        initialQuery: String = "",
        keepsSectionOrder: Bool = false,
        emptyQuerySelection: Int = 0,
        onHighlight: (@MainActor (PaletteItem?) -> Void)? = nil,
        onLeave: (@MainActor () -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.placeholder = placeholder
        self.symbol = symbol
        self.providers = providers
        self.showsRecent = showsRecent
        self.initialQuery = initialQuery
        self.keepsSectionOrder = keepsSectionOrder
        self.emptyQuerySelection = emptyQuerySelection
        self.onHighlight = onHighlight
        self.onLeave = onLeave
    }
}

/// An inline text entry page, used by argument-taking actions.
public struct PaletteTextInputSpec {
    public let id: String
    public var title: String
    public var placeholder: String
    public var symbol: String
    public var initialText: String
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
        self.submitTitle = submitTitle
        self.isValid = isValid
        self.submit = submit
        self.next = next
    }
}
