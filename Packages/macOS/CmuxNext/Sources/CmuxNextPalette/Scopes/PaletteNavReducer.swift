/// Which entry gestures are on (Debug Settings `palette.scopeEntry`) and
/// how deep scopes nest.
nonisolated public struct PaletteNavConfig: Equatable, Sendable {
    /// A prefix typed into an empty query enters its scope.
    public var prefixEntry: Bool
    /// A keyword plus Tab enters its scope.
    public var keywordEntry: Bool
    public var maxDepth: Int

    public init(prefixEntry: Bool = true, keywordEntry: Bool = true, maxDepth: Int = 8) {
        self.prefixEntry = prefixEntry
        self.keywordEntry = keywordEntry
        self.maxDepth = max(2, maxDepth)
    }
}

/// The palette's navigation state machine: `(state, event) -> (state',
/// effects)`, pure, with the scope graph as its environment. Rules:
/// plans/cmux-next/palette-scopes.md section 4.3; invariants (section 4.4)
/// are checked by `PaletteNavPropertyTests`.
nonisolated public struct PaletteNavReducer: Sendable {
    public var graph: PaletteScopeGraph
    public var config: PaletteNavConfig

    public init(graph: PaletteScopeGraph, config: PaletteNavConfig = PaletteNavConfig()) {
        self.graph = graph
        self.config = config
    }

    /// Applies `event` to `state` and returns the effects to perform, in
    /// order.
    public func reduce(_ state: inout PaletteNavState, _ event: PaletteNavEvent) -> [PaletteNavEffect] {
        switch event {
        case .open(let scope, let query):
            return open(&state, scope: scope, query: query)
        case .close:
            return close(&state)
        default:
            break
        }
        guard state.isOpen, !state.levels.isEmpty else { return [] }
        switch event {
        case .open, .close:
            return []
        case .setQuery(let text):
            return setQuery(&state, text)
        case .backspaceOnEmpty:
            guard state.levels[state.levels.count - 1].query.isEmpty else { return [] }
            return pop(&state, to: state.levels.count - 2)
        case .tab:
            return tab(&state)
        case .shiftTab:
            return pop(&state, to: state.levels.count - 2)
        case .escape:
            return escape(&state)
        case .popTo(let index):
            return pop(&state, to: index)
        case .activate(let rowID):
            return activate(&state, rowID: rowID)
        case .push(let scope, let row, let query):
            return push(&state, scope: scope, entry: .command(row), query: query)
        case .move(let delta):
            move(&state, by: delta)
            return []
        case .select(let rowID):
            let top = state.levels.count - 1
            if state.levels[top].rows.contains(where: { $0.id == rowID }) {
                state.levels[top].selection = rowID
                pin(&state.levels[top])
            }
            return []
        case .results(let levelID, let generation, let rows, let replace, let isFinal, let emptyQuerySelection):
            return accept(&state, levelID: levelID, generation: generation, rows: rows, replace: replace, isFinal: isFinal,
                          emptyQuerySelection: emptyQuerySelection)
        case .refresh:
            let top = state.levels.count - 1
            return [reload(&state.levels[top])]
        case .restart(let query):
            let top = state.levels.count - 1
            state.levels[top].rows = []
            return [edit(&state.levels[top], to: query)]
        }
    }

    // MARK: Open and close

    private func open(_ state: inout PaletteNavState, scope: PaletteScopeID?, query: String) -> [PaletteNavEffect] {
        var effects = close(&state)
        state.isOpen = true
        let target = scope.flatMap { $0 == .root ? nil : $0 }
        effects += push(&state, scope: .root, entry: .root, query: target == nil ? query : "", announce: false)
        guard let target else { return effects }
        effects += push(&state, scope: target, entry: .opened, query: query, announce: true)
        return effects
    }

    private func close(_ state: inout PaletteNavState) -> [PaletteNavEffect] {
        let effects = state.levels.reversed().map { PaletteNavEffect.cancel(levelID: $0.id) }
        state.levels = []
        state.isOpen = false
        return effects
    }

    // MARK: Stack

    private func push(_ state: inout PaletteNavState, scope: PaletteScopeID, entry: PaletteNavLevel.Entry, query: String,
                      announce: Bool = true) -> [PaletteNavEffect] {
        guard state.levels.count < config.maxDepth else { return [.refused(.depthLimit)] }
        let level = PaletteNavLevel(id: state.nextLevelID, scope: scope, entry: entry, query: query)
        state.nextLevelID += 1
        state.levels.append(level)
        var effects: [PaletteNavEffect] = [load(level)]
        if announce { effects.append(.announceEntered(scope)) }
        return effects
    }

    /// Pops every level above `index` (at least the root stays). The new top
    /// shows its cached rows, keeps its selection and reloads.
    private func pop(_ state: inout PaletteNavState, to index: Int) -> [PaletteNavEffect] {
        let keep = max(0, index) + 1
        guard keep < state.levels.count else { return [] }
        var effects: [PaletteNavEffect] = []
        while state.levels.count > keep {
            effects.append(.cancel(levelID: state.levels.removeLast().id))
        }
        let top = state.levels.count - 1
        state.levels[top].pendingSubmit = false
        effects.append(reload(&state.levels[top]))
        effects.append(.announceLeft(to: state.levels[top].scope))
        return effects
    }

    // MARK: Keys

    private func setQuery(_ state: inout PaletteNavState, _ text: String) -> [PaletteNavEffect] {
        let top = state.levels.count - 1
        let level = state.levels[top]
        guard level.query != text else { return [] }
        if config.prefixEntry, level.query.isEmpty, let first = text.first,
           let child = graph.child(of: level.scope, prefix: first), state.levels.count < config.maxDepth {
            return push(&state, scope: child.id, entry: .prefix(String(first)), query: String(text.dropFirst()))
        }
        return [edit(&state.levels[top], to: text)]
    }

    private func tab(_ state: inout PaletteNavState) -> [PaletteNavEffect] {
        let top = state.levels.count - 1
        let level = state.levels[top]
        if config.keywordEntry, let child = graph.child(of: level.scope, keyword: level.query),
           state.levels.count < config.maxDepth {
            let keyword = level.query.trimmingCharacters(in: .whitespaces).lowercased()
            // The keyword is consumed: the parent comes back with an empty
            // query (reloaded when the child pops).
            state.levels[top].query = ""
            state.levels[top].generation += 1
            state.levels[top].pendingReset = true
            state.levels[top].pendingSubmit = false
            state.levels[top].selectionPinned = false
            state.levels[top].pendingChoice = nil
            state.levels[top].isLoading = true
            return push(&state, scope: child.id, entry: .keyword(keyword), query: "")
        }
        guard let row = selectedRow(level) else { return [] }
        if let target = row.enters, graph.contains(target) {
            return push(&state, scope: target, entry: .row(row.id), query: "")
        }
        if let target = row.drills, graph.contains(target) {
            return push(&state, scope: target, entry: .drill(row.id), query: "")
        }
        return row.isEnabled ? [.openActions(rowID: row.id)] : []
    }

    private func escape(_ state: inout PaletteNavState) -> [PaletteNavEffect] {
        let top = state.levels.count - 1
        if state.levels[top].entry.isPushed { return pop(&state, to: top - 1) }
        if !state.levels[top].query.isEmpty { return [edit(&state.levels[top], to: "")] }
        return close(&state) + [.dismiss]
    }

    private func activate(_ state: inout PaletteNavState, rowID: String?) -> [PaletteNavEffect] {
        let top = state.levels.count - 1
        if let rowID {
            guard state.levels[top].rows.contains(where: { $0.id == rowID }) else { return [] }
            state.levels[top].selection = rowID
        } else if !state.levels[top].rowsAreCurrent, state.levels[top].rowsQuery != state.levels[top].query {
            // The rows on screen belong to an older query text (a refresh of the same text runs the
            // highlighted row at once).
            state.levels[top].pendingSubmit = true
            return []
        }
        let level = state.levels[top]
        guard let row = selectedRow(level) else { return [] }
        if let target = row.enters, graph.contains(target) {
            return push(&state, scope: target, entry: .row(row.id), query: "")
        }
        return row.isEnabled ? [.run(levelID: level.id, rowID: row.id)] : []
    }

    private func move(_ state: inout PaletteNavState, by delta: Int) {
        let top = state.levels.count - 1
        let rows = state.levels[top].rows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == state.levels[top].selection } ?? -1
        let next = ((current + delta) % rows.count + rows.count) % rows.count
        state.levels[top].selection = rows[next].id
        pin(&state.levels[top])
    }

    /// The user chose the selection: fresh rows of the current query keep it.
    private func pin(_ level: inout PaletteNavLevel) {
        level.pendingReset = false
        level.selectionPinned = true
        level.pendingChoice = nil
    }

    // MARK: Results

    private func accept(_ state: inout PaletteNavState, levelID: Int, generation: Int, rows: [PaletteNavRow],
                        replace: Bool, isFinal: Bool, emptyQuerySelection: Int?) -> [PaletteNavEffect] {
        guard let index = state.index(ofLevel: levelID), state.levels[index].generation == generation else { return [] }
        var level = state.levels[index]
        if let emptyQuerySelection { level.emptyQuerySelection = max(0, emptyQuerySelection) }
        let previousIndex = level.rows.firstIndex { $0.id == level.selection }
        if replace || level.rowsGeneration != generation {
            level.rows = Self.unique(rows)
        } else {
            level.rows = Self.unique(level.rows + rows)
        }
        level.rowsGeneration = generation
        level.rowsQuery = level.query
        level.isLoading = !isFinal
        if let choice = level.pendingChoice, level.rows.contains(where: { $0.id == choice }) {
            level.selection = choice
            level.pendingChoice = nil
        }
        let shown = level.selection.map { selection in level.rows.contains { $0.id == selection } } ?? false
        func fallback() -> String? {
            guard !level.rows.isEmpty else { return nil }
            return previousIndex.map { level.rows[min($0, level.rows.count - 1)].id } ?? defaultSelection(level)
        }
        if level.pendingReset {
            level.selection = defaultSelection(level)
            level.pendingReset = false
        } else if level.pendingChoice != nil {
            // A waiting Return's chosen row is still missing.
            if !shown { level.selection = fallback() }
            if !isFinal {
                state.levels[index] = level
                return []
            }
            // The query's rows are complete without it: Return runs nothing it did not show.
            level.pendingChoice = nil
            level.pendingSubmit = false
        } else if shown {
            // Kept by id.
        } else if level.selectionPinned, level.pendingSubmit, !isFinal {
            // Return waits for the chosen row: a later batch of this query may hold it. Meanwhile
            // the selection shows a row on screen.
            level.pendingChoice = level.selection
            level.selection = fallback()
            state.levels[index] = level
            return []
        } else {
            level.selection = fallback()
            // The chosen row is not in this query's results: Return runs nothing it did not show.
            if level.selectionPinned { level.pendingSubmit = false }
        }
        let submit = level.pendingSubmit && index == state.levels.count - 1
        level.pendingSubmit = false
        state.levels[index] = level
        return submit ? activate(&state, rowID: nil) : []
    }

    private func defaultSelection(_ level: PaletteNavLevel) -> String? {
        guard !level.rows.isEmpty else { return nil }
        let preferred = level.query.isEmpty ? level.emptyQuerySelection ?? graph.descriptor(level.scope)?.emptyQuerySelection ?? 0 : 0
        return level.rows[min(preferred, level.rows.count - 1)].id
    }

    // MARK: Helpers

    private func edit(_ level: inout PaletteNavLevel, to text: String) -> PaletteNavEffect {
        level.query = text
        level.pendingReset = true
        level.pendingSubmit = false
        level.selectionPinned = false
        level.pendingChoice = nil
        return reload(&level)
    }

    /// New generation for the same level; the rows on screen stay until
    /// its first batch lands.
    private func reload(_ level: inout PaletteNavLevel) -> PaletteNavEffect {
        level.generation += 1
        level.isLoading = true
        return load(level)
    }

    private func load(_ level: PaletteNavLevel) -> PaletteNavEffect {
        .load(levelID: level.id, scope: level.scope, query: level.query, generation: level.generation, context: level.context)
    }

    private func selectedRow(_ level: PaletteNavLevel) -> PaletteNavRow? {
        guard let selection = level.selection else { return nil }
        return level.rows.first { $0.id == selection }
    }

    static func unique(_ rows: [PaletteNavRow]) -> [PaletteNavRow] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }
    }
}
