public import Foundation

/// Stable public id of a palette scope: `tabs`, `workspaces`, `actions`,
/// app scopes `app:<appId>#<scope>`. The root scope is the full palette.
nonisolated public struct PaletteScopeID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }

    /// The full palette, always level 0 of an open palette.
    public static let root: PaletteScopeID = "root"
}

/// A palette scope as the catalog lists it: pure data, no item source.
/// plans/cmux-next/palette-scopes.md section 3.1.
nonisolated public struct PaletteScopeDescriptor: Hashable, Sendable {
    /// Where the prefix, the keyword and the scope row enter this scope.
    public enum Parents: Hashable, Sendable {
        /// Only from the root (the full palette).
        case root
        /// From any scope.
        case anywhere
        /// From these scopes.
        case only(Set<PaletteScopeID>)

        public func allows(_ parent: PaletteScopeID) -> Bool {
            switch self {
            case .root: parent == .root
            case .anywhere: true
            case .only(let set): set.contains(parent)
            }
        }
    }

    public let id: PaletteScopeID
    /// Chip text and scope row title.
    public var title: String
    /// SF Symbol of the chip and the scope row.
    public var symbol: String
    public var placeholder: String
    /// One punctuation or symbol character typed into an empty query, or
    /// nil. Letters, digits and whitespace are refused by the graph so that
    /// typing a word never enters a scope.
    public var prefix: String?
    /// Lowercased words: an exact keyword plus Tab enters the scope.
    public var keywords: [String]
    public var parents: Parents
    /// The row an empty query selects, clamped to the rows. Search Tabs
    /// uses 1: the current tab is first, so Return switches back.
    public var emptyQuerySelection: Int
    /// The catalog action that opens the scope (shortcut, menu, CLI).
    public var openAction: String?
    /// `client` for built-in scopes, `app:<id>` for app scopes.
    public var owner: String

    public init(
        id: PaletteScopeID,
        title: String,
        symbol: String,
        placeholder: String,
        prefix: String? = nil,
        keywords: [String] = [],
        parents: Parents = .root,
        emptyQuerySelection: Int = 0,
        openAction: String? = nil,
        owner: String = "client"
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.placeholder = placeholder
        self.prefix = prefix
        self.keywords = keywords.map { $0.lowercased() }
        self.parents = parents
        self.emptyQuerySelection = max(0, emptyQuerySelection)
        self.openAction = openAction
        self.owner = owner
    }
}
