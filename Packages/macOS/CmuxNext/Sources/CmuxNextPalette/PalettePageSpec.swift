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

    public init(
        id: String,
        title: String,
        placeholder: String,
        symbol: String = "command",
        providers: [any PaletteProvider],
        showsRecent: Bool = false
    ) {
        self.id = id
        self.title = title
        self.placeholder = placeholder
        self.symbol = symbol
        self.providers = providers
        self.showsRecent = showsRecent
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

    public init(
        id: String,
        title: String,
        placeholder: String,
        symbol: String = "pencil",
        initialText: String = "",
        submitTitle: @escaping @MainActor (String) -> String,
        isValid: @escaping @MainActor (String) -> Bool = { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
        submit: @escaping @MainActor (String) -> Void
    ) {
        self.id = id
        self.title = title
        self.placeholder = placeholder
        self.symbol = symbol
        self.initialText = initialText
        self.submitTitle = submitTitle
        self.isValid = isValid
        self.submit = submit
    }
}
