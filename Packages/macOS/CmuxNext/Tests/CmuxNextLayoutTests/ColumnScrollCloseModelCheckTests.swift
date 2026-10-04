import CoreGraphics
import CmuxNextDesign
import Testing
@testable import CmuxNextLayout

/// Exhaustive model check of the column strip scroll after closes,
/// creations and focus moves (close-focus.md, user 2026-10-01: "what is
/// the best way to handle scroll ... in horizontal column scroll"). Strips
/// of up to 4 columns (widths 30, 55 or 100 percent of the viewport, two
/// viewport widths), every focused column and every reachable scroll
/// offset, every step to depth 6. The focus successor is
/// `FocusAfterClose.pane` (one pane per column). Docked columns are not
/// in `ColumnStrip` (they never scroll), so they cannot affect this math.
///
/// After each step the spring settles (`animated: false` targets the same
/// offset an animation ends at) and S1-S6 are checked:
/// S1 the focused column is visible, S2 the offset is clamped, S3 a
/// focused column that stays focused and visible keeps its screen x unless
/// the clamp forces a move, S4 a reveal is minimal, S5 a close left of
/// the viewport does not move what the user sees, S6 a second sync of the
/// same strip does not scroll again.
/// Nonisolated and serialized: the exploration is seconds to minutes of CPU,
/// which on the main actor (this target's default isolation) stalls every
/// main-actor test in the process past its time limit; serialized keeps the
/// mutant cases from filling the cooperative pool at once.
@Suite(.serialized) nonisolated struct ColumnScrollCloseModelCheckTests {
    struct World: Hashable {
        var widths: [Int]          // percent of the viewport, by column order
        var ids: [Int]
        var focused: Int?          // column id (one pane per column)
        var viewport: Int
        var state: ColumnScrollState
        var nextID: Int
        var history: [Int]
    }

    enum Step: Hashable {
        case close(Int)            // a column, by the user or anyone else
        case newColumn(width: Int) // after the focused one, focused
        case focusLeft, focusRight
    }

    static let gap: CGFloat = 8

    static func strip(_ world: World) -> ColumnStrip {
        makeStrip(world.widths.map { CGFloat($0) * CGFloat(world.viewport) / 100 }, ids: world.ids.map(String.init),
                  viewport: CGFloat(world.viewport), gap: gap)
    }

    static func pane(_ id: Int?) -> PaneID? { id.map { PaneID("p\($0)") } }

    static func steps(_ world: World) -> [Step] {
        var result = world.ids.map { Step.close($0) } + [.focusLeft, .focusRight]
        if world.ids.count < 4 { result += [.newColumn(width: 55), .newColumn(width: 100)] }
        return result
    }

    static func apply(_ step: Step, _ world: World, mutant: String? = nil) -> World {
        var next = world
        var source = ColumnFocusSource.keyboard
        switch step {
        case .close(let id):
            guard let index = world.ids.firstIndex(of: id) else { return world }
            next.ids.remove(at: index)
            next.widths.remove(at: index)
            next.history = world.history.filter { $0 != id }
            next.focused = FocusAfterClose.pane(focused: world.focused, before: world.ids.map { [$0] },
                                                after: world.ids.map { $0 == id ? [] : [$0] }, history: next.history,
                                                policy: .previousNeighbor)
            source = .programmatic
        case .newColumn(let width):
            let at = world.focused.flatMap { world.ids.firstIndex(of: $0) }.map { $0 + 1 } ?? world.ids.count
            next.ids.insert(world.nextID, at: at)
            next.widths.insert(width, at: at)
            next.focused = world.nextID
            next.nextID += 1
        case .focusLeft, .focusRight:
            guard let f = world.focused, let i = world.ids.firstIndex(of: f) else { return world }
            let j = step == .focusLeft ? i - 1 : i + 1
            guard world.ids.indices.contains(j) else { return world }
            next.focused = world.ids[j]
        }
        if let f = next.focused { next.history = [f] + next.history.filter { $0 != f } }
        let old = next.state.spring.target
        next.state.reduce(.sync(strip(next), focused: pane(next.focused), source: source, animated: false))
        if let mutant { mutate(&next, mutant: mutant, before: world, previousTarget: old) }
        return next
    }

    /// Broken variants of the reducer's result; each must be caught.
    static func mutate(_ world: inout World, mutant: String, before: World, previousTarget: CGFloat) {
        let strip = strip(world)
        var target = world.state.spring.target
        switch mutant {
        case "noReveal":
            target = strip.clamp(previousTarget)
        case "center":
            if let f = world.focused, let i = world.ids.firstIndex(of: f) { target = ColumnViewOffset.center(strip.columns[i].frame, current: target, strip: strip) }
        case "noClamp":
            target -= 1
        case "noAnchor":
            if world.focused == before.focused, let f = world.focused, let i = world.ids.firstIndex(of: f) {
                target = ColumnViewOffset.fit(strip.columns[i].frame, current: strip.clamp(previousTarget), strip: strip)
            }
        default:
            break
        }
        world.state.spring.target = target
        world.state.spring.value = target
    }

    static func check(_ step: Step, before: World, after: World) -> [String] {
        var bad: [String] = []
        let strip = strip(after)
        let offset = after.state.spring.target
        if after.state.spring.value != offset { bad.append("settle value \(after.state.spring.value) != target \(offset)") }
        // S2
        if offset < -0.01 || offset > strip.maxOffset + 0.01 { bad.append("S2 offset \(offset) outside 0...\(strip.maxOffset)") }
        // S1
        if let f = after.focused, let i = after.ids.firstIndex(of: f), !strip.isColumnVisible(i, at: offset) {
            bad.append("S1 focused column \(f) not visible at \(offset)")
        }
        let old = Self.strip(before)
        let oldOffset = before.state.spring.target
        let oldScreen = { (id: Int) in old.index(of: ColumnID("c\(id)")).map { old.columns[$0].frame.minX - oldOffset } }
        let newScreen = { (id: Int) in strip.index(of: ColumnID("c\(id)")).map { strip.columns[$0].frame.minX - offset } }
        // S3: same focus, visible before, unclamped: no jump.
        if let f = before.focused, f == after.focused, let i = before.ids.firstIndex(of: f), old.isColumnVisible(i, at: oldOffset),
           let a = oldScreen(f), let b = newScreen(f), abs(a - b) > 0.01 {
            let unclamped = strip.columns[strip.index(of: ColumnID("c\(f)"))!].frame.minX - a
            if abs(strip.clamp(unclamped) - unclamped) < 0.01 { bad.append("S3 focused \(f) jumped \(a) -> \(b) on \(step)") }
        }
        // S4: a changed focus is revealed with the least motion from the
        // anchored offset (the old focus keeps its screen x when it survives).
        // the restore point: closing the column just opened right of the
        // focused one puts back the offset from before the open (an undo
        // of that scroll, close-focus.md decision 5) instead of the least
        // motion.
        if case .close(let id) = step, before.focused == id, let restore = before.state.restore, restore.opened == ColumnID("c\(id)"),
           after.focused.map({ ColumnID("c\($0)") }) == restore.column, let i = strip.index(of: restore.column) {
            let expected = strip.clamp(strip.columns[i].frame.minX + restore.relativeOffset)
            if abs(offset - expected) > 0.01 { bad.append("S4r restore expected \(expected), got \(offset)") }
        } else if after.focused != before.focused, let f = after.focused, let i = after.ids.firstIndex(of: f) {
            let anchor = before.focused.flatMap { id in oldScreen(id).flatMap { a in strip.index(of: ColumnID("c\(id)")).map { strip.columns[$0].frame.minX - a } } }
                ?? oldOffset
            let minimal = ColumnViewOffset.fit(strip.columns[i].frame, current: strip.clamp(anchor), strip: strip)
            if abs(offset - minimal) > 0.01 { bad.append("S4 \(step): offset \(offset), minimal \(minimal) from \(anchor)") }
        }
        // S5: closing a column wholly left of the viewport keeps the visible columns put.
        if case .close(let id) = step, id != before.focused, let i = before.ids.firstIndex(of: id),
           old.columns[i].frame.maxX + gap <= oldOffset + 0.01,
           let survivor = before.ids.first(where: { $0 != id && (oldScreen($0) ?? -1) >= -0.01 }),
           let a = oldScreen(survivor), let b = newScreen(survivor), abs(a - b) > 0.01 {
            let unclamped = oldOffset - (old.columns[i].frame.width + gap)
            if abs(strip.clamp(unclamped) - unclamped) < 0.01 { bad.append("S5 column \(survivor) moved \(a) -> \(b)") }
        }
        // S6: a second identical sync does not scroll.
        var again = after.state
        again.reduce(.sync(strip, focused: pane(after.focused), source: .programmatic, animated: false))
        if abs(again.spring.target - offset) > 0.01 { bad.append("S6 second sync \(offset) -> \(again.spring.target)") }
        return bad
    }

    /// Renames columns by position so states that differ only in fresh ids
    /// are one state (the reducer compares ids only by identity).
    static func canonical(_ world: World) -> World {
        var map: [Int: Int] = [:]
        for id in world.ids { map[id] = map.count }
        let col = { (c: ColumnID) -> ColumnID? in Int(c.rawValue.dropFirst()).flatMap { map[$0] }.map { ColumnID("c\($0)") } }
        let pan = { (p: PaneID) -> PaneID? in Int(p.rawValue.dropFirst()).flatMap { map[$0] }.map { PaneID("p\($0)") } }
        var next = world
        next.ids = world.ids.map { map[$0]! }
        next.focused = world.focused.flatMap { map[$0] }
        next.history = world.history.compactMap { map[$0] }
        next.nextID = map.count
        var state = world.state
        state.strip = state.strip.map { _ in strip(next) }
        state.focusedPane = state.focusedPane.flatMap(pan)
        state.focusedColumn = state.focusedColumn.flatMap(col)
        state.remembered = Dictionary(uniqueKeysWithValues: state.remembered.compactMap { key, value in
            col(key).flatMap { k in pan(value).map { (k, $0) } }
        })
        if let restore = state.restore {
            if let column = col(restore.column), let opened = col(restore.opened) {
                state.restore = .init(column: column, opened: opened, relativeOffset: restore.relativeOffset)
            } else {
                state.restore = nil
            }
        }
        next.state = state
        return next
    }

    static func explore(depth: Int, mutant: String? = nil) -> (states: Int, transitions: Int, violations: [String]) {
        var frontier: Set<World> = []
        let choices = [30, 55, 100]
        func lists(_ n: Int) -> [[Int]] { n == 0 ? [[]] : lists(n - 1).flatMap { p in choices.map { p + [$0] } } }
        for n in 1...4 {
            for widths in lists(n) {
                for viewport in [1000, 1400] {
                    for focused in 0..<n {
                        let ids = Array(0..<n)
                        var world = World(widths: widths, ids: ids, focused: focused, viewport: viewport, state: ColumnScrollState(),
                                          nextID: n, history: [focused])
                        world.state.reduce(.sync(strip(world), focused: pane(focused), source: .programmatic, animated: false))
                        frontier.insert(world)
                        // The same focus reached from each side: the other reachable offsets.
                        for other in 0..<n where other != focused {
                            var w = World(widths: widths, ids: ids, focused: other, viewport: viewport, state: ColumnScrollState(),
                                          nextID: n, history: [other])
                            w.state.reduce(.sync(strip(w), focused: pane(other), source: .programmatic, animated: false))
                            w.focused = focused
                            w.history = [focused, other]
                            w.state.reduce(.sync(strip(w), focused: pane(focused), source: .keyboard, animated: false))
                            frontier.insert(w)
                        }
                    }
                }
            }
        }
        var seen = frontier
        var transitions = 0
        var violations: [String] = []
        for _ in 0..<depth {
            var next: Set<World> = []
            for world in frontier {
                for step in steps(world) {
                    let after = apply(step, world, mutant: mutant)
                    transitions += 1
                    let bad = check(step, before: world, after: after)
                    if !bad.isEmpty, violations.count < 8 {
                        violations.append("ids \(world.ids) w \(world.widths) vp \(world.viewport) off \(world.state.spring.target) f \(String(describing: world.focused)) \(step): \(bad)")
                    }
                    let key = canonical(after)
                    if seen.insert(key).inserted { next.insert(key) }
                }
            }
            frontier = next
        }
        return (seen.count, transitions, violations)
    }

    @Test func everyReachableStripStateKeepsTheScrollRules() {
        let result = Self.explore(depth: 6)
        #expect(result.violations.isEmpty, "\(result.violations)")
        print("ColumnScroll close model check: \(result.states) states, \(result.transitions) transitions")
    }

    @Test(arguments: ["noReveal", "center", "noClamp", "noAnchor"])
    func mutantIsCaught(_ name: String) {
        #expect(!Self.explore(depth: 3, mutant: name).violations.isEmpty, "mutant \(name) not caught")
    }
}
