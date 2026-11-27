import Foundation

/// One chosen value of a multi-value step, drawn as a chip in the search field (New Group Chat's
/// members). A click on it, or Backspace on an empty query when it is the last one, shows
/// `remove()`: the same page without it.
public struct PaletteToken {
    /// Stable value (a participant id or typed address).
    public let id: String
    /// The chip's text.
    public let title: String
    /// SF Symbol drawn before the title.
    public let symbol: String
    /// The page with this value removed.
    public let remove: @MainActor () -> PalettePageSpec

    public init(id: String, title: String, symbol: String = "person.fill", remove: @escaping @MainActor () -> PalettePageSpec) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.remove = remove
    }
}

// MARK: - Palette v2 scope bar and typed tokens (`PaletteV2Look.scoped`)

nonisolated extension PaletteScopeID {
    /// The v2 scope bar's This Workspace: the current workspace's panes and tabs, then the commands.
    public static let thisWorkspace: PaletteScopeID = "thisWorkspace"
    /// The v2 scope bar's Sessions: every pane, tab and agent chat, nothing else.
    public static let sessions: PaletteScopeID = "sessions"
}

/// A segment of the v2 scope bar under the field. Each is a scope of the navigation stack, opened directly above
/// the root (Backspace on its empty query goes back to All), so the bar reads the segment off the shown level.
public nonisolated enum PaletteScopeSegment: Int, Sendable, CaseIterable {
    /// Today's root results.
    case all
    case thisWorkspace
    case sessions

    /// The scope the segment shows.
    public var scope: PaletteScopeID {
        switch self {
        case .all: .root
        case .thisWorkspace: .thisWorkspace
        case .sessions: .sessions
        }
    }

    /// The segment a level of `scope` belongs to; nil for a scope of no segment (a pushed page).
    public init?(exactly scope: PaletteScopeID?) {
        switch scope {
        case nil, PaletteScopeID.root?: self = .all
        case PaletteScopeID.thisWorkspace?: self = .thisWorkspace
        case PaletteScopeID.sessions?: self = .sessions
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .all: PaletteStrings.scopeAll
        case .thisWorkspace: PaletteStrings.scopeThisWorkspace
        case .sessions: PaletteStrings.scopeSessions
        }
    }
}

/// A typed token of the v2 scope bar (the Mail search pattern): "Session contains: X" keeps the rows whose title
/// contains X, "Workspace contains: X" the rows whose subtitle (a session's workspace) contains X.
public nonisolated struct PaletteScopeToken: Sendable, Hashable {
    public nonisolated enum Kind: String, Sendable, CaseIterable {
        case session
        case workspace
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    /// The suggestion row's muted lead ("Session contains:").
    var prefix: String {
        switch kind {
        case .session: PaletteStrings.sessionContains
        case .workspace: PaletteStrings.workspaceContains
        }
    }

    /// The chip's text in the field ("Session: X").
    var chipTitle: String {
        switch kind {
        case .session: PaletteStrings.sessionTokenChip(text)
        case .workspace: PaletteStrings.workspaceTokenChip(text)
        }
    }

    var symbol: String {
        switch kind {
        case .session: "text.bubble"
        case .workspace: "rectangle.stack"
        }
    }

    /// Whether a row with this title and subtitle passes (case and diacritic insensitive).
    func matches(title: String, subtitle: String?) -> Bool {
        let field = kind == .session ? title : (subtitle ?? "")
        return field.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// The scope bar's and the tokens' filters (pure; O(rows) or O(entries)).
enum PaletteScopeFilter {
    /// Row ids of the token suggestions start with this: the token filter never takes them out.
    static let suggestionPrefix = "scopeToken:"
    /// The suggestions' section id: the v2 grouping keeps that section first (`PaletteV2Grouping.regroup`).
    static let suggestionsSectionID = "scopeToken.suggestions"

    static var suggestionsSection: PaletteSection {
        PaletteSection(id: suggestionsSectionID, title: PaletteStrings.sectionSuggestions, order: -200)
    }

    /// Sessions: the panes and tabs (agent chats included), no sidebar group.
    static func sessionEntries(_ entries: [PaletteNavigationEntry]) -> [PaletteNavigationEntry] {
        entries.filter { entry in
            guard case .group = entry.kind else { return true }
            return false
        }
    }

    /// This Workspace: the panes and tabs of workspace `workspaceID`; none without one.
    static func entries(_ entries: [PaletteNavigationEntry], inWorkspace workspaceID: String?) -> [PaletteNavigationEntry] {
        guard let workspaceID else { return [] }
        return entries.filter { $0.workspaceID == workspaceID }
    }

    /// The rows every token passes, sections left empty dropped. Suggestion rows always stay.
    static func filtered(_ sections: [PaletteResultSection], tokens: [PaletteScopeToken]) -> [PaletteResultSection] {
        guard !tokens.isEmpty else { return sections }
        return sections.compactMap { section in
            let rows = section.rows.filter { row in
                row.id.hasPrefix(suggestionPrefix) || tokens.allSatisfy { $0.matches(title: row.item.title, subtitle: row.item.subtitle) }
            }
            return rows.isEmpty ? nil : PaletteResultSection(section: section.section, rows: rows)
        }
    }

    /// The tokens a typed query offers, one per kind; none for a blank query.
    static func suggestions(for query: String) -> [PaletteScopeToken] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return PaletteScopeToken.Kind.allCases.map { PaletteScopeToken(kind: $0, text: text) }
    }

    /// A suggestion's row: "Session contains: X", the prefix muted and X in the primary color (the row draws the
    /// highlighted scalars emphasized, the rest muted). `choose` runs on Return or a click.
    @MainActor
    static func suggestionRow(_ token: PaletteScopeToken, choose: @escaping @MainActor () -> Void) -> PaletteRow {
        let lead = token.prefix + " "
        let leadCount = lead.unicodeScalars.count
        var item = PaletteItem(
            id: suggestionPrefix + token.kind.rawValue,
            title: lead + token.text,
            symbol: token.symbol,
            section: suggestionsSection,
            primary: PaletteCommand(id: "addToken", title: PaletteStrings.addScopeToken, symbol: "return", effect: .performKeepingOpen(choose))
        )
        // Not a use to remember: the row is made from the query.
        item.frecencyKey = nil
        return PaletteRow(item: item, highlights: Array(leadCount..<leadCount + token.text.unicodeScalars.count), score: 0)
    }
}

extension PaletteModel {
    /// The scope bar's chosen segment: the shown level's, else All. Read from `scopeChips`, so views observe it.
    public var scopeSegment: PaletteScopeSegment {
        PaletteScopeSegment(exactly: scopeChips.last?.scope) ?? .all
    }

    /// The chips the field draws: with the scope bar, a segment's own level is the bar's, not a chip.
    public var fieldScopeChips: [PaletteScopeChip] {
        guard experiments.look.showsScopeBar else { return scopeChips }
        return scopeChips.filter { PaletteScopeSegment(exactly: $0.scope) == nil }
    }

    /// The field's chips for chosen values: the page's (`pageTokens`), then the scope bar's typed tokens.
    /// The typed tokens show only where they filter (a segment's page), not on a page pushed above it.
    var fieldTokenChips: [(title: String, symbol: String)] {
        let page = pageTokens.map { (title: $0.title, symbol: $0.symbol) }
        guard !scopeTokens.isEmpty, current.map({ scopeTokensApply(to: $0) }) == true else { return page }
        return page + scopeTokens.map { (title: $0.chipTitle, symbol: $0.symbol) }
    }

    /// A click on a scope bar segment, or Cmd-1 to Cmd-3: opens its scope with the query typed so far.
    public func chooseScopeSegment(_ segment: PaletteScopeSegment) {
        guard experiments.look.showsScopeBar else { return }
        // Already there: All is the root alone, another segment its own level.
        if segment == .all ? nav.depth <= 1 : scopeChips.last?.scope == segment.scope { return }
        let text = query
        send(.open(scope: segment == .all ? nil : segment.scope, query: text))
    }

    /// The Esc chip in the field: closes the palette, whatever the query (Escape first clears a typed one).
    public func closeFromEscChip() {
        send(.close)
        onDismiss?()
    }

    /// Chooses a token suggestion: the token joins the field and the query clears. From All it opens Sessions,
    /// where the rows it filters are.
    func addScopeToken(_ token: PaletteScopeToken) {
        guard !scopeTokens.contains(token) else { return }
        scopeTokens.append(token)
        if scopeSegment == .all {
            send(.open(scope: PaletteScopeSegment.sessions.scope, query: ""))
        } else if query.isEmpty {
            send(.refresh)
        } else {
            query = ""
        }
    }

    /// Takes out typed token `index` (a click on its chip).
    func removeScopeToken(at index: Int) {
        guard scopeTokens.indices.contains(index) else { return }
        scopeTokens.remove(at: index)
        send(.refresh)
    }

    /// Backspace on an empty query: takes out the last typed token. False with none.
    func removeLastScopeToken() -> Bool {
        guard !scopeTokens.isEmpty, current.map({ scopeTokensApply(to: $0) }) == true else { return false }
        removeScopeToken(at: scopeTokens.count - 1)
        return true
    }

    /// Whether the scope bar's tokens and suggestions apply to `state`: a list page of a segment, in the scoped look.
    func scopeTokensApply(to state: PageState) -> Bool {
        guard experiments.look.showsScopeBar, case .list(let page) = state.kind else { return false }
        return PaletteScopeSegment(exactly: page.scope) != nil
    }

    /// `sections` with the typed tokens applied (`deliver`).
    func scopeTokenFiltered(_ sections: [PaletteResultSection], state: PageState) -> [PaletteResultSection] {
        guard !scopeTokens.isEmpty, scopeTokensApply(to: state) else { return sections }
        return PaletteScopeFilter.filtered(sections, tokens: scopeTokens)
    }

    /// `sections` after the token suggestions for `query`, in All and Sessions with a typed query.
    func withScopeTokenSuggestions(_ sections: [PaletteResultSection], query: String, state: PageState) -> [PaletteResultSection] {
        guard scopeTokensApply(to: state), case .list(let page) = state.kind, page.scope != PaletteScopeID.thisWorkspace else { return sections }
        let rows = PaletteScopeFilter.suggestions(for: query).filter { !scopeTokens.contains($0) }.map { token in
            PaletteScopeFilter.suggestionRow(token) { [weak self] in self?.addScopeToken(token) }
        }
        guard !rows.isEmpty else { return sections }
        return [PaletteResultSection(section: PaletteScopeFilter.suggestionsSection, rows: rows)] + sections
    }
}
