public import CmuxNextDesign

/// How the titlebar Back / Forward right-click list is laid out (Debug Settings
/// `history.menuLayout`, plans/cmux-next/history.md 4.2c).
public nonisolated enum LocationTrailMenuLayout: String, CaseIterable, Hashable, Sendable, TunableChoice {
    /// The entries Back and Forward walk (the scope), then the window's other
    /// places (other workspaces and chats) under their own header. The default.
    case scopeThenWindow
    /// Only the entries Back and Forward walk (the R69 list).
    case scope
    /// The window's places split by kind: browser pages, chats and pages, terminals.
    case byKind

    public var tunableTitle: String {
        switch self {
        case .scopeThenWindow: "Scope, then other workspaces and chats"
        case .scope: "Scope only (what Back walks)"
        case .byKind: "Split by kind: browser, chats and pages, terminals"
        }
    }
}

/// One group of a Back or Forward list; every kind but `scope` shows a header.
public nonisolated struct LocationTrailMenuSection: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// What Back and Forward walk; no header.
        case scope
        /// The window's places outside the scope (other workspaces).
        case otherWorkspaces
        case browser
        /// Agent chats and cmux pages (everything that is not a terminal or a browser page).
        case chatsAndPages
        case terminals
    }

    public let kind: Kind
    public let items: [LocationTrailListItem]

    public init(kind: Kind, items: [LocationTrailListItem]) {
        self.kind = kind
        self.items = items
    }
}

extension LocationTrail {
    /// Rows per added section (other workspaces, each kind): the list stays short, like a
    /// browser's history menu. The scope section keeps every entry.
    public static let menuSectionLimit = 12

    /// The headed list of a Back or Forward button under `layout`, nearest first, empty sections
    /// left out. The added sections hold each place once (its nearest entry). With the `surface`
    /// scope the page's own entry menu is the list, so this is empty.
    public func menuSections(_ direction: LocationTrailDirection, scope: HistoryScope, layout: LocationTrailMenuLayout,
                             isAvailable: (HistoryLocation) -> Bool = { _ in true }) -> [LocationTrailMenuSection] {
        guard scope != .surface else { return [] }
        let scoped = list(direction, scope: scope, isAvailable: isAvailable)
        switch layout {
        case .scope:
            return scoped.isEmpty ? [] : [LocationTrailMenuSection(kind: .scope, items: scoped)]
        case .scopeThenWindow:
            let shown = Set(scoped.map(\.entry.location.key))
            let others = Self.distinctPlaces(list(direction, scope: .window, isAvailable: isAvailable)
                .filter { !shown.contains($0.entry.location.key) })
            return [LocationTrailMenuSection(kind: .scope, items: scoped),
                    LocationTrailMenuSection(kind: .otherWorkspaces, items: others)].filter { !$0.items.isEmpty }
        case .byKind:
            let window = Self.distinctPlaces(list(direction, scope: .window, isAvailable: isAvailable), limit: .max)
            let kinds: [(LocationTrailMenuSection.Kind, (HistoryLocation) -> Bool)] = [
                (.browser, { $0.content == .browser && $0.page == nil }),
                (.chatsAndPages, { $0.page != nil || $0.content == .other }),
                (.terminals, { $0.content == .terminal && $0.page == nil }),
            ]
            return kinds.map { kind, matches in
                LocationTrailMenuSection(kind: kind, items: Array(window.filter { matches($0.entry.location) }.prefix(Self.menuSectionLimit)))
            }.filter { !$0.items.isEmpty }
        }
    }

    /// Each place (tab on its machine) once, at its nearest entry, at most `limit` rows.
    static func distinctPlaces(_ items: [LocationTrailListItem], limit: Int = menuSectionLimit) -> [LocationTrailListItem] {
        var seen: Set<HistoryLocation.Key> = []
        var result: [LocationTrailListItem] = []
        for item in items where result.count < limit && seen.insert(item.entry.location.key).inserted {
            result.append(item)
        }
        return result
    }
}
