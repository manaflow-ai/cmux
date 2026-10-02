import Foundation
import Testing
@testable import CmuxNextDesign

/// Exhaustive model check of the focus successor rules (user 2026-10-01:
/// "we need to formally verify the correct behavior for when user closes
/// workspace/terminal/pane/etc. like what is the next thing to focus on").
/// Every reachable state of a small universe is explored breadth first to
/// a fixed depth; the invariants of `FocusAfterClose` (close-focus.md) are
/// checked after every step. Each mutant breaks one rule and must be caught.
/// Nonisolated and serialized: the exploration is seconds to minutes of CPU,
/// which on the main actor (this target's default isolation) stalls every
/// main-actor test in the process past its time limit; serialized keeps the
/// mutant cases from filling the cooperative pool at once.
@Suite(.serialized) nonisolated struct FocusAfterCloseModelCheckTests {
    typealias PaneRule = @Sendable (_ focused: Int?, _ before: [[Int]], _ after: [[Int]], _ history: [Int], _ policy: CloseFocusPolicy) -> Int?

    static let realPane: PaneRule = { FocusAfterClose.pane(focused: $0, before: $1, after: $2, history: $3, policy: $4) }

    // MARK: Panes

    /// A window's view of one screen: columns of pane ids, the focused
    /// pane, the focus history (newest first) and the next fresh id.
    struct PaneWorld: Hashable {
        var columns: [[Int]]
        var focused: Int?
        var history: [Int]
        var nextID: Int
    }

    enum PaneStep: Hashable {
        case closePane(Int)       // any pane, by the user or anyone else
        case closeColumn(Int)     // a whole column at once (close-pane of its last pane, or a batch)
        case focus(Int)           // a user focus change
        case split                // a new pane after the focused one in its column
        case newColumn            // a new column right of the focused one
    }

    /// Renames panes by their position (column-major), so states that
    /// differ only in fresh ids are one state. The rules never compare ids
    /// by value, only by identity, so this is a sound reduction.
    static func canonical(_ world: PaneWorld) -> PaneWorld {
        var map: [Int: Int] = [:]
        for pane in world.columns.flatMap({ $0 }) { map[pane] = map.count }
        return PaneWorld(columns: world.columns.map { $0.map { map[$0]! } }, focused: world.focused.flatMap { map[$0] },
                         history: world.history.compactMap { map[$0] }, nextID: map.count)
    }

    struct Stats {
        var states = 0
        var transitions = 0
        var closes = 0
        var violations: [String] = []
    }

    static func steps(_ world: PaneWorld, maxPanes: Int, maxColumns: Int) -> [PaneStep] {
        let panes = world.columns.flatMap { $0 }
        var result: [PaneStep] = panes.map { .closePane($0) } + world.columns.indices.map { .closeColumn($0) } + panes.map { .focus($0) }
        if let focused = world.focused, let column = world.columns.firstIndex(where: { $0.contains(focused) }) {
            if panes.count < maxPanes, world.columns[column].count < 3 { result.append(.split) }
            if panes.count < maxPanes, world.columns.count < maxColumns { result.append(.newColumn) }
        }
        return result
    }

    static func remember(_ pane: Int?, _ history: [Int]) -> [Int] {
        guard let pane else { return history }
        return [pane] + history.filter { $0 != pane }
    }

    /// One step. Returns the next world and, for a close, what the rule saw.
    static func apply(_ step: PaneStep, to world: PaneWorld, rule: PaneRule, policy: CloseFocusPolicy) -> PaneWorld {
        var next = world
        func close(_ removed: Set<Int>) {
            let before = world.columns
            let after = before.map { $0.filter { !removed.contains($0) } }.filter { !$0.isEmpty }
            let surviving = Set(after.flatMap { $0 })
            next.columns = after
            next.history = world.history.filter(surviving.contains)
            let ruleAfter = before.map { $0.filter { !removed.contains($0) } }
            next.focused = rule(world.focused, before, ruleAfter, next.history, policy)
            next.history = remember(next.focused, next.history)
        }
        switch step {
        case .closePane(let pane): close([pane])
        case .closeColumn(let index): close(Set(world.columns[index]))
        case .focus(let pane):
            next.focused = pane
            next.history = remember(pane, world.history)
        case .split:
            guard let focused = world.focused, let c = world.columns.firstIndex(where: { $0.contains(focused) }),
                  let i = world.columns[c].firstIndex(of: focused) else { return world }
            next.columns[c].insert(world.nextID, at: i + 1)
            next.focused = world.nextID
            next.history = remember(world.nextID, world.history)
            next.nextID += 1
        case .newColumn:
            guard let focused = world.focused, let c = world.columns.firstIndex(where: { $0.contains(focused) }) else { return world }
            next.columns.insert([world.nextID], at: c + 1)
            next.focused = world.nextID
            next.history = remember(world.nextID, world.history)
            next.nextID += 1
        }
        return next
    }

    /// The invariants of a close step, stated from the spec independently
    /// of the implementation (column indices, not the code's search).
    static func check(_ step: PaneStep, before: PaneWorld, after: PaneWorld, policy: CloseFocusPolicy, rule: PaneRule) -> [String] {
        var bad: [String] = []
        let removed: Set<Int>
        switch step {
        case .closePane(let pane): removed = [pane]
        case .closeColumn(let index): removed = Set(before.columns[index])
        default: return bad
        }
        let surviving = Set(after.columns.flatMap { $0 })
        // C3: nil only when nothing survives.
        if (after.focused == nil) != surviving.isEmpty { bad.append("C3 focus \(String(describing: after.focused)) with \(surviving.count) panes") }
        // C2: the successor survives.
        if let focus = after.focused, !surviving.contains(focus) { bad.append("C2 focus \(focus) removed") }
        guard let old = before.focused else { return bad }
        // C1: an unfocused close (whoever closed it) never moves focus.
        if !removed.contains(old) {
            if after.focused != old { bad.append("C1 \(old) -> \(String(describing: after.focused)) on unfocused close") }
            return bad
        }
        // C4: deterministic.
        let ruleAfter = before.columns.map { $0.filter { !removed.contains($0) } }
        let history = before.history.filter(surviving.contains)
        if rule(old, before.columns, ruleAfter, history, policy) != rule(old, before.columns, ruleAfter, history, policy) {
            bad.append("C4 nondeterministic")
        }
        guard let focus = after.focused else { return bad }
        // R: the configured rule.
        if policy == .mostRecent, let recent = history.first {
            if focus != recent { bad.append("RM expected most recent \(recent), got \(focus)") }
            return bad
        }
        guard let c = before.columns.firstIndex(where: { $0.contains(old) }) else { return bad }
        let column = before.columns[c]
        let alive = column.filter(surviving.contains)
        if !alive.isEmpty {
            // R1: same column, the nearest previous survivor, else the nearest next one.
            let i = column.firstIndex(of: old)!
            let expected = column[..<i].last(where: surviving.contains) ?? column[(i + 1)...].first(where: surviving.contains)
            if focus != expected { bad.append("R1 expected \(String(describing: expected)) in column, got \(focus)") }
        } else {
            // R2: the nearest surviving column to the left, else the right;
            // inside it the most recent pane, else its first.
            let left = before.columns[..<c].lastIndex { $0.contains(where: surviving.contains) }
            let right = before.columns[(c + 1)...].firstIndex { $0.contains(where: surviving.contains) }
            guard let target = left ?? right else { return bad }
            let panes = before.columns[target].filter(surviving.contains)
            let expected = history.first(where: panes.contains) ?? panes.first
            if focus != expected { bad.append("R2 expected \(String(describing: expected)) (column \(target)), got \(focus)") }
        }
        return bad
    }

    /// Breadth-first exploration from every initial layout of up to
    /// `maxColumns` columns of up to 3 panes, to `depth` steps.
    static func explorePanes(depth: Int, maxColumns: Int = 4, maxPanes: Int = Self.maxPanes, policy: CloseFocusPolicy, rule: PaneRule) -> Stats {
        var stats = Stats()
        var frontier: Set<PaneWorld> = []
        // Initial layouts: every composition of 1...maxColumns columns of 1...3 panes, each pane focused.
        func layouts(_ columns: Int) -> [[Int]] {
            guard columns > 0 else { return [[]] }
            return layouts(columns - 1).flatMap { prefix in (1...3).map { prefix + [$0] } }
        }
        for count in 1...maxColumns {
            for sizes in layouts(count) where sizes.reduce(0, +) <= maxPanes {
                var id = 0
                let columns = sizes.map { size -> [Int] in defer { id += size }; return Array(id..<(id + size)) }
                for focused in columns.flatMap({ $0 }) {
                    frontier.insert(PaneWorld(columns: columns, focused: focused, history: [focused], nextID: id))
                }
            }
        }
        var seen = frontier
        stats.states = seen.count
        for _ in 0..<depth {
            var next: Set<PaneWorld> = []
            for world in frontier {
                for step in steps(world, maxPanes: maxPanes, maxColumns: maxColumns) {
                    let after = apply(step, to: world, rule: rule, policy: policy)
                    stats.transitions += 1
                    if case .focus = step {} else if case .split = step {} else if case .newColumn = step {} else { stats.closes += 1 }
                    let bad = check(step, before: world, after: after, policy: policy, rule: rule)
                    if !bad.isEmpty, stats.violations.count < 5 { stats.violations.append("\(world) \(step): \(bad)") }
                    let key = canonical(after)
                    if seen.insert(key).inserted { next.insert(key) }
                }
            }
            frontier = next
            stats.states = seen.count
        }
        return stats
    }

    /// Depth and pane bound; `CMUX_MODELCHECK_DEPTH` deepens a local run.
    static let depth = ProcessInfo.processInfo.environment["CMUX_MODELCHECK_DEPTH"].flatMap(Int.init) ?? 6
    static let maxPanes = ProcessInfo.processInfo.environment["CMUX_MODELCHECK_PANES"].flatMap(Int.init) ?? 6

    @Test func paneRulePreviousNeighborHoldsInEveryReachableState() {
        let stats = Self.explorePanes(depth: Self.depth, policy: .previousNeighbor, rule: Self.realPane)
        #expect(stats.violations.isEmpty, "\(stats.violations)")
        #expect(stats.states > 10_000)
        print("FocusAfterClose.pane previousNeighbor: \(stats.states) states, \(stats.transitions) transitions, \(stats.closes) closes")
    }

    @Test func paneRuleMostRecentHoldsInEveryReachableState() {
        let stats = Self.explorePanes(depth: Self.depth, policy: .mostRecent, rule: Self.realPane)
        #expect(stats.violations.isEmpty, "\(stats.violations)")
        print("FocusAfterClose.pane mostRecent: \(stats.states) states, \(stats.transitions) transitions, \(stats.closes) closes")
    }

    /// Mutants: each breaks one rule and must be caught.
    @Test(arguments: [
        "historyAlways", "nextFirst", "rightColumnFirst", "firstPaneOfColumn", "moveOnUnfocusedClose", "nilWhenColumnGone",
    ])
    func paneMutantIsCaught(_ name: String) {
        let mutant: PaneRule = { focused, before, after, history, policy in
            let real = FocusAfterClose.pane(focused: focused, before: before, after: after, history: history, policy: policy)
            let surviving = Set(after.flatMap { $0 })
            switch name {
            case "historyAlways":
                // The old app rule: the most recently focused survivor anywhere.
                if let focused, !surviving.contains(focused), let recent = history.first(where: surviving.contains) { return recent }
                return real
            case "nextFirst":
                guard let focused, !surviving.contains(focused), let c = before.firstIndex(where: { $0.contains(focused) }),
                      let pick = FocusAfterClose.neighbor(of: focused, in: before[c], preferNext: true, where: surviving.contains) else { return real }
                return pick
            case "rightColumnFirst":
                guard let focused, !surviving.contains(focused), let c = before.firstIndex(where: { $0.contains(focused) }),
                      !before[c].contains(where: surviving.contains),
                      let right = before[(c + 1)...].first(where: { $0.contains(where: surviving.contains) }) else { return real }
                return right.first(where: surviving.contains)
            case "firstPaneOfColumn":
                guard let real, let column = after.first(where: { $0.contains(real) }) else { return real }
                return column.first
            case "moveOnUnfocusedClose":
                if let focused, surviving.contains(focused), surviving.count > 1 { return after.flatMap { $0 }.first { $0 != focused } }
                return real
            case "nilWhenColumnGone":
                guard let focused, let c = before.firstIndex(where: { $0.contains(focused) }), !before[c].contains(where: surviving.contains) else { return real }
                return nil
            default:
                return real
            }
        }
        let stats = Self.explorePanes(depth: 4, policy: .previousNeighbor, rule: mutant)
        #expect(!stats.violations.isEmpty, "mutant \(name) not caught")
    }

    // MARK: Tabs

    /// Strips of up to 5 tabs, any subset hidden (collapsed group members),
    /// every close sequence to depth 5.
    static func exploreTabs(rule: (Int?, [Int], [Int], Set<Int>) -> Int?) -> (sequences: Int, violations: [String]) {
        var sequences = 0
        var violations: [String] = []
        func walk(_ tabs: [Int], _ selected: Int?, _ hidden: Set<Int>, depth: Int) {
            guard depth > 0, !tabs.isEmpty else { sequences += 1; return }
            for closed in tabs {
                let surviving = tabs.filter { $0 != closed }
                let shown = Set(surviving).subtracting(hidden)
                let pick = rule(selected, tabs, surviving, shown)
                var bad: [String] = []
                if let selected, selected != closed, pick != selected { bad.append("T1 moved on unselected close") }
                if (pick == nil) != surviving.isEmpty { bad.append("T3 nil with survivors") }
                if let pick, !surviving.contains(pick) { bad.append("T2 picked removed") }
                if selected == closed, let pick, !shown.isEmpty, !shown.contains(pick) { bad.append("T2 picked hidden \(pick)") }
                if selected == closed, let i = tabs.firstIndex(of: closed), !shown.isEmpty {
                    let expected = tabs[(i + 1)...].first(where: shown.contains) ?? tabs[..<i].last(where: shown.contains)
                    if pick != expected { bad.append("TR expected \(String(describing: expected)) got \(String(describing: pick))") }
                }
                if !bad.isEmpty, violations.count < 5 { violations.append("\(tabs) sel \(String(describing: selected)) hidden \(hidden) close \(closed): \(bad)") }
                walk(surviving, pick, hidden, depth: depth - 1)
            }
        }
        for count in 1...5 {
            let tabs = Array(0..<count)
            for mask in 0..<(1 << count) {
                let hidden = Set(tabs.filter { mask & (1 << $0) != 0 })
                for selected in tabs where !hidden.contains(selected) { walk(tabs, selected, hidden, depth: 5) }
            }
        }
        return (sequences, violations)
    }

    @Test func tabRuleHoldsForEveryCloseSequence() {
        let result = Self.exploreTabs { FocusAfterClose.tab(selected: $0, old: $1, surviving: $2, shown: $3) }
        #expect(result.violations.isEmpty, "\(result.violations)")
        print("FocusAfterClose.tab: \(result.sequences) close sequences")
    }

    @Test func tabMutantsAreCaught() {
        // The old rule ignored hidden tabs; another picks the left neighbor first.
        let ignoresHidden = Self.exploreTabs { selected, old, surviving, _ in
            FocusAfterClose.tab(selected: selected, old: old, surviving: surviving, shown: Set(surviving))
        }
        #expect(!ignoresHidden.violations.isEmpty)
        let leftFirst = Self.exploreTabs { selected, old, surviving, shown in
            guard let selected, !surviving.contains(selected) else { return selected }
            return FocusAfterClose.neighbor(of: selected, in: old, preferNext: false, where: shown.contains) ?? surviving.first
        }
        #expect(!leftFirst.violations.isEmpty)
    }

    // MARK: Workspaces

    @Test func workspaceRuleHoldsForEveryCloseSequence() {
        var sequences = 0
        var violations: [String] = []
        func walk(_ list: [Int], _ shown: Int?, depth: Int) {
            guard depth > 0, !list.isEmpty else { sequences += 1; return }
            for closed in list {
                let surviving = list.filter { $0 != closed }
                let pick = FocusAfterClose.workspace(shown: shown, old: list, surviving: surviving)
                if let shown, shown != closed, pick != shown { violations.append("W1 \(list) \(shown) close \(closed)") }
                if (pick == nil) != surviving.isEmpty { violations.append("W3 \(list)") }
                if shown == closed, let i = list.firstIndex(of: closed) {
                    let expected = i + 1 < list.count ? list[i + 1] : (i > 0 ? list[i - 1] : nil)
                    if pick != expected { violations.append("WR \(list) close \(closed) got \(String(describing: pick))") }
                }
                walk(surviving, pick, depth: depth - 1)
            }
        }
        for selected in 0..<5 { walk(Array(0..<5), selected, depth: 5) }
        #expect(violations.isEmpty, "\(violations.prefix(5))")
        print("FocusAfterClose.workspace: \(sequences) close sequences")
    }
}
