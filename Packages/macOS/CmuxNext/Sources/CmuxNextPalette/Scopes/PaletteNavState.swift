/// The palette's navigation state: a stack of scope levels, each with its
/// own query, rows and selection. Client view state (OWNERSHIP-PRINCIPLES:
/// the client owns the view); it never leaves the palette. Changed only by
/// `PaletteNavReducer`. plans/cmux-next/palette-scopes.md section 4.
nonisolated public struct PaletteNavState: Equatable, Sendable {
    public internal(set) var isOpen = false
    /// Level 0 is the root scope while open; empty while closed.
    public internal(set) var levels: [PaletteNavLevel] = []
    /// Next level id. Ids are unique for the life of the state, so a batch
    /// for a popped level can never land on a new level.
    public internal(set) var nextLevelID = 1

    public init() {}

    public var top: PaletteNavLevel? { levels.last }
    public var depth: Int { levels.count }

    /// Chips, root first: the scope of every level.
    public var scopePath: [PaletteScopeID] { levels.map(\.scope) }

    func index(ofLevel id: Int) -> Int? { levels.firstIndex { $0.id == id } }
}

/// One level of the palette stack.
nonisolated public struct PaletteNavLevel: Equatable, Sendable, Identifiable {
    /// How the level was entered.
    public enum Entry: Equatable, Sendable {
        /// Level 0.
        case root
        /// Opened directly (shortcut, menu, CLI) above the root.
        case opened
        /// A prefix typed into the parent's empty query.
        case prefix(String)
        /// The parent's query was this keyword and the user pressed Tab.
        case keyword(String)
        /// The scope row with this id was chosen (Return, Tab, click).
        case row(String)
        /// Tab on the parent's row with this id (its actions, its tabs).
        case drill(String)
        /// A command of the parent's row with this id (nil: no row) pushed a
        /// page of its own (argument picker, text entry, nested list). Such
        /// pages need not be in the scope graph.
        case command(String?)

        /// Entered inside this palette session (Escape pops it).
        public var isPushed: Bool {
            switch self {
            case .root, .opened: false
            case .prefix, .keyword, .row, .drill, .command: true
            }
        }
    }

    public let id: Int
    public let scope: PaletteScopeID
    public let entry: Entry
    public internal(set) var query: String
    /// Bumps on every query change and refresh; batches carry it.
    public internal(set) var generation: Int
    /// The rows last accepted, for the generation `rowsGeneration`.
    public internal(set) var rows: [PaletteNavRow] = []
    public internal(set) var rowsGeneration: Int = 0
    /// A batch of `generation` is still expected.
    public internal(set) var isLoading: Bool
    public internal(set) var selection: String?
    /// The query changed: the next accepted batch selects the default row
    /// instead of keeping the old selection.
    public internal(set) var pendingReset: Bool
    /// Return arrived while `rows` were stale: run once fresh rows land.
    public internal(set) var pendingSubmit = false
    /// The user chose `selection` (arrows, a click) after the last query change. Fresh rows keep
    /// it by id instead of selecting their top row, and a waiting Return runs it, or nothing when
    /// the current query has no such row (Return runs exactly the highlighted row).
    public internal(set) var selectionPinned = false
    /// The chosen row a waiting Return runs when a later batch of this query brings it (the
    /// selection meanwhile shows a row that is on screen).
    public internal(set) var pendingChoice: String?
    /// The empty-query row index the last batch asked for, if any.
    public internal(set) var emptyQuerySelection: Int?

    init(id: Int, scope: PaletteScopeID, entry: Entry, query: String) {
        self.id = id
        self.scope = scope
        self.entry = entry
        self.query = query
        self.generation = 1
        self.isLoading = true
        self.pendingReset = true
    }

    /// The rows on screen belong to the current query.
    public var rowsAreCurrent: Bool { rowsGeneration == generation }

    /// The drill or scope row this level was entered from.
    public var context: String? {
        switch entry {
        case .drill(let row), .row(let row): row
        case .command(let row): row
        default: nil
        }
    }
}

/// What navigation needs from a result row. Titles and commands stay in
/// the palette model.
nonisolated public struct PaletteNavRow: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    /// A scope row: Return or Tab enters this scope.
    public var enters: PaletteScopeID?
    /// Tab drills into this scope with the row as context.
    public var drills: PaletteScopeID?
    public var isEnabled: Bool

    public init(id: String, enters: PaletteScopeID? = nil, drills: PaletteScopeID? = nil, isEnabled: Bool = true) {
        self.id = id
        self.enters = enters
        self.drills = drills
        self.isEnabled = isEnabled
    }
}
