import CmuxNextPalette

/// A scope graph like the built-in one: tabs (`@`, Search Tabs), workspaces
/// (`#`), commands (`>`), settings (`,`), the scope list (`?`), item
/// actions (drill only, from anywhere), and a nested `tabActions` scope that
/// only `tabs` can enter.
enum PaletteNavFixtures {
    static let tabs: PaletteScopeID = "tabs"
    static let workspaces: PaletteScopeID = "workspaces"
    static let commands: PaletteScopeID = "commands"
    static let settings: PaletteScopeID = "settings"
    static let scopes: PaletteScopeID = "scopes"
    static let actions: PaletteScopeID = "actions"
    static let closed: PaletteScopeID = "closed"
    static let notes: PaletteScopeID = "app:cmux/notes#notes"

    static func scope(_ id: PaletteScopeID, prefix: String? = nil, keywords: [String] = [],
                      parents: PaletteScopeDescriptor.Parents = .root,
                      emptyQuerySelection: Int = 0) -> PaletteScopeDescriptor {
        PaletteScopeDescriptor(id: id, title: id.rawValue.capitalized, symbol: "circle", placeholder: "Search \(id.rawValue)…",
                               prefix: prefix, keywords: keywords, parents: parents, emptyQuerySelection: emptyQuerySelection)
    }

    static var graph: PaletteScopeGraph {
        PaletteScopeGraph(
            root: scope(.root),
            scopes: [
                scope(tabs, prefix: "@", keywords: ["tabs", "tab"], emptyQuerySelection: 1),
                scope(workspaces, prefix: "#", keywords: ["workspaces"]),
                scope(commands, prefix: ">", keywords: ["commands"]),
                scope(settings, prefix: ",", keywords: ["settings"]),
                scope(scopes, prefix: "?"),
                scope(actions, parents: .only([])),
                // Recently closed tabs, entered from Tabs by `!` or keyword.
                scope(closed, prefix: "!", keywords: ["closed"], parents: .only([tabs])),
                scope(notes, keywords: ["notes"]),
            ]
        )
    }

    static var reducer: PaletteNavReducer { PaletteNavReducer(graph: graph) }

    static func rows(_ ids: [String], drills: PaletteScopeID? = actions) -> [PaletteNavRow] {
        ids.map { PaletteNavRow(id: $0, drills: drills) }
    }
}

/// Drives a reducer and answers every `load` with fixed rows per scope, the
/// way the palette model answers with its sources.
struct PaletteNavDriver {
    var reducer = PaletteNavFixtures.reducer
    var state = PaletteNavState()
    var effects: [PaletteNavEffect] = []
    /// Rows a scope returns for any query.
    var rowsByScope: [PaletteScopeID: [PaletteNavRow]] = [:]

    @discardableResult
    mutating func send(_ event: PaletteNavEvent, answer: Bool = true) -> [PaletteNavEffect] {
        let produced = reducer.reduce(&state, event)
        effects += produced
        guard answer else { return produced }
        var all = produced
        for case .load(let levelID, let scope, _, let generation, _) in produced {
            all += send(.results(levelID: levelID, generation: generation, rows: rowsByScope[scope] ?? [], replace: true, isFinal: true))
        }
        return all
    }

    var chips: [String] { state.scopePath.map(\.rawValue) }
    var top: PaletteNavLevel { state.top! }
}
