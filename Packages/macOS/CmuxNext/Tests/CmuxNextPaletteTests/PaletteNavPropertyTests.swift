import CmuxNextPalette
import Testing

/// Seeded random event sequences against the scope state machine's
/// invariants (plans/cmux-next/palette-scopes.md section 4.4). Batches are
/// delivered late, out of order, duplicated, streamed and stale.
@Suite struct PaletteNavPropertyTests {
    typealias F = PaletteNavFixtures

    nonisolated static let seeds: [UInt64] = Array(1...500)
    nonisolated static let steps = 60

    // MARK: Generator

    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A run: the reducer, its state, and the loads not yet answered.
    struct Run {
        var rng: SplitMix64
        var reducer: PaletteNavReducer
        var state = PaletteNavState()
        var pending: [(levelID: Int, scope: PaletteScopeID, generation: Int)] = []
        /// Every `load` ever emitted, to send stale batches later.
        var history: [(levelID: Int, generation: Int)] = []

        init(seed: UInt64) {
            rng = SplitMix64(state: seed)
            var config = PaletteNavConfig()
            config.maxDepth = 3 + Int(seed % 4)
            reducer = PaletteNavReducer(graph: F.graph, config: config)
        }

        mutating func randomRows() -> [PaletteNavRow] {
            let ids = ["r0", "r1", "r2", "r3", "r4", "r5"]
            let count = Int.random(in: 0...5, using: &rng)
            let scopes = reducer.graph.order + [PaletteScopeID("missing")]
            return (0..<count).map { _ in
                var row = PaletteNavRow(id: ids.randomElement(using: &rng)!)
                switch Int.random(in: 0..<6, using: &rng) {
                case 0: row.enters = scopes.randomElement(using: &rng)
                case 1, 2: row.drills = F.actions
                case 3: row.drills = scopes.randomElement(using: &rng)
                default: break
                }
                row.isEnabled = Int.random(in: 0..<8, using: &rng) != 0
                return row
            }
        }

        mutating func randomEvent() -> PaletteNavEvent {
            let queries = ["", "a", "ab", "@", "#x", ">", "?", "!", "tabs", "Notes ", "x@", ",", "closed"]
            let roll = Int.random(in: 0..<100, using: &rng)
            switch roll {
            case 0..<4:
                let scopes: [PaletteScopeID?] = [nil, .root, F.tabs, F.workspaces, F.notes, F.closed, "missing"]
                return .open(scope: scopes.randomElement(using: &rng)!, query: queries.randomElement(using: &rng)!)
            case 4..<6: return .close
            case 6..<24: return .setQuery(queries.randomElement(using: &rng)!)
            case 24..<32: return .backspaceOnEmpty
            case 32..<40: return .tab
            case 40..<43: return .shiftTab
            case 43..<48: return .escape
            case 48..<51: return .popTo(Int.random(in: -1...6, using: &rng))
            case 51..<56:
                let row = Bool.random(using: &rng) ? nil : ["r0", "r1", "r2", "zz"].randomElement(using: &rng)!
                return .activate(row)
            case 56..<62: return .move(Int.random(in: -3...3, using: &rng))
            case 62..<64: return .select(["r0", "r1", "r2", "zz"].randomElement(using: &rng)!)
            case 64..<66: return .refresh
            case 66: return .push(["page.rename", "page.pick"].randomElement(using: &rng)!, row: Bool.random(using: &rng) ? "r0" : nil)
            default:
                // A batch: usually for a pending load, sometimes stale.
                if !pending.isEmpty, Int.random(in: 0..<5, using: &rng) != 0 {
                    let index = Int.random(in: 0..<pending.count, using: &rng)
                    let load = pending[index]
                    let isFinal = Bool.random(using: &rng)
                    if isFinal { pending.remove(at: index) }
                    return .results(levelID: load.levelID, generation: load.generation, rows: randomRows(),
                                    replace: Bool.random(using: &rng), isFinal: isFinal)
                }
                let old = history.randomElement(using: &rng) ?? (levelID: 0, generation: 0)
                return .results(levelID: old.levelID, generation: old.generation - Int.random(in: 0...1, using: &rng),
                                rows: randomRows(), replace: true, isFinal: true)
            }
        }

        mutating func apply(_ event: PaletteNavEvent) -> [PaletteNavEffect] {
            let effects = reducer.reduce(&state, event)
            for case .load(let levelID, let scope, _, let generation, _) in effects {
                pending.append((levelID, scope, generation))
                history.append((levelID, generation))
            }
            return effects
        }
    }

    // MARK: Invariants

    /// I1 to I6. Returns the first violation.
    static func violation(_ state: PaletteNavState, _ effects: [PaletteNavEffect], _ reducer: PaletteNavReducer) -> String? {
        let graph = reducer.graph
        if !state.isOpen {
            return state.levels.isEmpty ? nil : "I1: closed with levels"
        }
        guard let root = state.levels.first, root.scope == .root, root.entry == .root else { return "I1: no root at level 0" }
        if state.levels.dropFirst().contains(where: { $0.entry == .root }) { return "I1: root entry above level 0" }
        if state.depth > reducer.config.maxDepth { return "I2: depth \(state.depth)" }
        let ids = state.levels.map(\.id)
        if ids != ids.sorted() || Set(ids).count != ids.count || (ids.last ?? 0) >= state.nextLevelID { return "I2: ids \(ids)" }
        for (index, level) in state.levels.enumerated() {
            if let selection = level.selection, !level.rows.contains(where: { $0.id == selection }) {
                return "I3: selection \(selection) not in rows of level \(index)"
            }
            if level.rowsAreCurrent, !level.rows.isEmpty, level.selection == nil, !level.pendingReset {
                return "I3: current rows without selection at level \(index)"
            }
            if level.rowsGeneration > level.generation { return "I4: rowsGeneration ahead at level \(index)" }
            if index == 0 { continue }
            let parent = state.levels[index - 1].scope
            switch level.entry {
            case .root: return "I5: root entry"
            case .opened: if index != 1 { return "I5: opened at \(index)" }
            case .prefix, .keyword: if !graph.canEnter(level.scope, from: parent) { return "I5: \(level.scope) from \(parent)" }
            case .row, .drill: if !graph.contains(level.scope) { return "I5: unknown \(level.scope)" }
            case .command: break
            }
        }
        for case .load(let levelID, let scope, let query, let generation, _) in effects {
            guard let level = state.levels.first(where: { $0.id == levelID }) else { return "I6: load for a dead level" }
            if level.scope != scope || level.generation != generation || level.query != query { return "I6: load out of date" }
        }
        return nil
    }

    /// What the user sees: chips, queries and selections.
    static func visible(_ state: PaletteNavState) -> [String] {
        state.levels.map { "\($0.scope)|\($0.query)|\($0.selection ?? "-")" }
    }

    /// The state without level ids, for comparing two opens.
    static func shape(_ state: PaletteNavState) -> [String] {
        state.levels.map { "\($0.scope)|\($0.entry)|\($0.query)|\($0.generation)|\($0.rows)|\($0.selection ?? "-")|\($0.isLoading)" }
    }

    // MARK: Properties

    @Test(arguments: seeds)
    func invariantsHoldOnRandomSequences(seed: UInt64) {
        var run = Run(seed: seed)
        _ = run.apply(.open(scope: nil, query: ""))
        for step in 0..<Self.steps {
            let event = run.randomEvent()
            let effects = run.apply(event)
            if let problem = Self.violation(run.state, effects, run.reducer) {
                Issue.record("seed \(seed) step \(step) \(event): \(problem)")
                return
            }
        }
    }

    @Test(arguments: seeds)
    func roundTripsAndStaleBatches(seed: UInt64) {
        var run = Run(seed: seed)
        _ = run.apply(.open(scope: nil, query: ""))
        for step in 0..<Self.steps {
            _ = run.apply(run.randomEvent())
            guard run.state.isOpen, let top = run.state.top else { continue }
            let label = "seed \(seed) step \(step)"

            // P3: a batch of an older generation changes nothing.
            if top.generation > 1 {
                var probe = run
                let before = probe.state
                let effects = probe.reducer.reduce(&probe.state, .results(levelID: top.id, generation: top.generation - 1,
                                                                            rows: [PaletteNavRow(id: "stale")], replace: true, isFinal: true))
                #expect(effects.isEmpty && probe.state == before, "\(label): P3")
            }

            // P1: prefix in, Backspace out.
            if top.query.isEmpty, run.state.depth < run.reducer.config.maxDepth,
               let child = run.reducer.graph.children(of: top.scope).first(where: { $0.prefix != nil }), let prefix = child.prefix {
                var probe = run
                let before = Self.visible(probe.state)
                _ = probe.apply(.setQuery(prefix))
                #expect(probe.state.top?.scope == child.id, "\(label): P1 entered")
                _ = probe.apply(.backspaceOnEmpty)
                #expect(Self.visible(probe.state) == before, "\(label): P1 restored")
            }

            // P2: drill in, Backspace out.
            if run.state.depth < run.reducer.config.maxDepth, let selection = top.selection,
               let row = top.rows.first(where: { $0.id == selection }), row.drills != nil, row.enters == nil,
               !(run.reducer.config.keywordEntry && run.reducer.graph.child(of: top.scope, keyword: top.query) != nil) {
                var probe = run
                let before = Self.visible(probe.state)
                _ = probe.apply(.tab)
                if probe.state.depth == run.state.depth + 1 {
                    _ = probe.apply(.backspaceOnEmpty)
                    #expect(Self.visible(probe.state) == before, "\(label): P2 restored")
                }
            }

            // P4: Escape closes within depth + 2; Backspace never closes.
            do {
                var probe = run
                for _ in 0..<(probe.state.depth * 4) { _ = probe.apply(.backspaceOnEmpty) }
                #expect(probe.state.isOpen, "\(label): P4 backspace closed")
                probe = run
                var escapes = 0
                while probe.state.isOpen, escapes <= run.state.depth + 2 {
                    _ = probe.apply(.escape)
                    escapes += 1
                }
                #expect(!probe.state.isOpen, "\(label): P4 escape did not close")
            }

            // P6: a plain edit changes only the top level.
            do {
                var probe = run
                let below = Array(probe.state.levels.dropLast())
                _ = probe.apply(.setQuery(top.query + "z"))
                #expect(Array(probe.state.levels.prefix(below.count)) == below, "\(label): P6")
            }
        }
    }

    @Test(arguments: seeds.prefix(100))
    func closeThenOpenIsAFreshOpen(seed: UInt64) {
        var run = Run(seed: seed)
        _ = run.apply(.open(scope: nil, query: ""))
        for _ in 0..<Self.steps { _ = run.apply(run.randomEvent()) }
        for scope in [nil, PaletteScopeID.root, F.tabs, F.notes, "missing"] as [PaletteScopeID?] {
            var reused = run.state
            _ = run.reducer.reduce(&reused, .close)
            let reopened = run.reducer.reduce(&reused, .open(scope: scope, query: "q"))
            var fresh = PaletteNavState()
            let opened = run.reducer.reduce(&fresh, .open(scope: scope, query: "q"))
            #expect(Self.shape(reused) == Self.shape(fresh), "seed \(seed) \(String(describing: scope)): P5")
            #expect(reopened.count == opened.count, "seed \(seed): P5 effects")
        }
    }

    @Test func reducerIsDeterministic() {
        for seed in Self.seeds.prefix(50) {
            var a = Run(seed: seed)
            var b = Run(seed: seed)
            for _ in 0..<Self.steps {
                let event = a.randomEvent()
                #expect(b.randomEvent() == event)
                #expect(a.apply(event) == b.apply(event))
            }
            #expect(a.state == b.state)
        }
    }
}
