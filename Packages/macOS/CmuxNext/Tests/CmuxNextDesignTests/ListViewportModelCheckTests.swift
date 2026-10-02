import CoreGraphics
import Testing
@testable import CmuxNextDesign

/// Exhaustive model check of the sidebar list scroll rules
/// (`ListViewport`, close-focus.md): lists of up to 5 rows 10, 20 or 30
/// points tall, viewports of 20, 40 and 70 points, padding 4, every scroll
/// offset in 5 point steps, every focused row,
/// and every change (remove a row, insert a row, move focus, remove the
/// focused row with its successor focused) to depth 3. V1-V6 are checked
/// after every step; each mutant breaks one and must be caught.
/// Nonisolated and serialized: the exploration is seconds to minutes of CPU,
/// which on the main actor (this target's default isolation) stalls every
/// main-actor test in the process past its time limit; serialized keeps the
/// mutant cases from filling the cooperative pool at once.
@Suite(.serialized) nonisolated struct ListViewportModelCheckTests {
    typealias Viewport = ListViewport<Int>
    typealias Settle = @Sendable (_ new: Viewport, _ old: Viewport, _ offset: CGFloat, _ focused: Int?, _ newFocus: Int?) -> CGFloat

    static let padding: CGFloat = 4
    static let real: Settle = { new, old, offset, focused, newFocus in
        new.settle(from: old, offset: offset, focused: focused, newFocus: newFocus, padding: padding)
    }

    struct World: Hashable {
        var heights: [Int: Int]   // id -> height
        var order: [Int]
        var viewport: Int
        var offset: CGFloat
        var focused: Int?
        var nextID: Int

        var list: Viewport {
            var y: CGFloat = 0
            var items: [Viewport.Item] = []
            for id in order {
                let h = CGFloat(heights[id]! * 10)
                items.append(.init(id: id, start: y, length: h))
                y += h
            }
            return Viewport(items: items, viewport: CGFloat(viewport * 10), content: max(y, CGFloat(viewport * 10)))
        }
    }

    enum Step: Hashable {
        case remove(Int)
        case insert(at: Int, height: Int)
        case focus(Int)
    }

    static func steps(_ world: World) -> [Step] {
        var result = world.order.map { Step.remove($0) } + world.order.map { Step.focus($0) }
        if world.order.count < 5 { for i in 0...world.order.count { result += [.insert(at: i, height: 1), .insert(at: i, height: 3)] } }
        return result
    }

    static func apply(_ step: Step, _ world: World, settle: Settle) -> World {
        var next = world
        switch step {
        case .remove(let id):
            next.order.removeAll { $0 == id }
            next.heights[id] = nil
            if world.focused == id {
                next.focused = FocusAfterClose.workspace(shown: id, old: world.order, surviving: next.order)
            }
        case .insert(let at, let height):
            next.order.insert(world.nextID, at: at)
            next.heights[world.nextID] = height
            next.nextID += 1
        case .focus(let id):
            next.focused = id
        }
        next.offset = settle(next.list, world.list, world.offset, world.focused, next.focused)
        return next
    }

    static func screenStart(_ list: Viewport, _ id: Int, _ offset: CGFloat) -> CGFloat? { list.item(id).map { $0.start - offset } }

    static func check(_ step: Step, before: World, after: World, settle: Settle) -> [String] {
        var bad: [String] = []
        let old = before.list, new = after.list
        let offset = after.offset
        // V1: clamped.
        if offset < -0.001 || offset > new.maxOffset + 0.001 { bad.append("V1 offset \(offset) outside 0...\(new.maxOffset)") }
        let focusChanged = after.focused != before.focused
        let wasVisible = before.focused.flatMap { f in old.item(f).map { old.isFullyVisible($0, at: before.offset, padding: padding) } } ?? false
        // V2: revealed when it must be.
        if let f = after.focused, let item = new.item(f), focusChanged || wasVisible,
           !new.isFullyVisible(item, at: offset, padding: 0) {
            bad.append("V2 focus \(f) not visible at \(offset)")
        }
        // V3: no jump for a visible focused row that stays focused.
        if let f = before.focused, !focusChanged, wasVisible, let a = screenStart(old, f, before.offset),
           let b = screenStart(new, f, offset) {
            let unclamped = (new.item(f)!.start - old.item(f)!.start) + before.offset
            if abs(a - b) > 0.001, abs(new.clamp(unclamped) - unclamped) < 0.001 { bad.append("V3 focused \(f) jumped \(a) -> \(b)") }
        }
        // V4: minimal reveal (never further than aligning the nearer edge).
        if let f = after.focused, let item = new.item(f), focusChanged {
            let anchored = new.anchored(from: old, offset: before.offset, focused: before.focused)
            // Wholly in view: nothing moves; else the nearer edge with padding.
            let minimal = new.isFullyVisible(item, at: anchored, padding: 0) ? anchored : new.reveal(item, from: anchored, padding: padding)
            if abs(offset - minimal) > 0.001 { bad.append("V4 not minimal: \(offset) vs \(minimal)") }
        }
        // V5: a change entirely before the viewport keeps what the user sees.
        if case .remove(let id) = step, id != before.focused, let removed = old.item(id), removed.end <= before.offset + 0.001,
           let anchor = old.items.first(where: { $0.end > before.offset + 0.001 && $0.id != id }),
           let a = screenStart(old, anchor.id, before.offset), let b = screenStart(new, anchor.id, offset) {
            let unclamped = before.offset - removed.length
            if abs(a - b) > 0.001, abs(new.clamp(unclamped) - unclamped) < 0.001 { bad.append("V5 row \(anchor.id) moved \(a) -> \(b)") }
        }
        if case .insert(let at, let h) = step, at < before.order.count,
           CGFloat(before.order[..<at].reduce(0) { $0 + before.heights[$1]! * 10 }) <= before.offset + 0.001,
           before.offset > 0.001,
           let anchor = old.items.first(where: { $0.end > before.offset + 0.001 }),
           let a = screenStart(old, anchor.id, before.offset), let b = screenStart(new, anchor.id, offset) {
            let unclamped = before.offset + CGFloat(h * 10)
            if abs(a - b) > 0.001, abs(new.clamp(unclamped) - unclamped) < 0.001, !focusChanged { bad.append("V5 insert moved row \(anchor.id) \(a) -> \(b)") }
        }
        // V6: settling the same geometry again changes nothing.
        let again = settle(new, new, offset, after.focused, after.focused)
        if abs(again - offset) > 0.001 { bad.append("V6 second settle \(offset) -> \(again)") }
        return bad
    }

    static func explore(depth: Int, settle: Settle) -> (states: Int, transitions: Int, violations: [String]) {
        var frontier: Set<World> = []
        func lists(_ n: Int) -> [[Int]] {
            guard n > 0 else { return [[]] }
            return lists(n - 1).flatMap { p in (1...3).map { p + [$0] } }
        }
        for n in 1...4 {
            for heights in lists(n) {
                for viewport in [2, 4, 7] {
                    let total = heights.reduce(0, +)
                    for offset in stride(from: 0, through: max(0, total - viewport) * 10, by: 5) {
                        for focused in 0..<n {
                            var world = World(heights: Dictionary(uniqueKeysWithValues: heights.enumerated().map { ($0, $1) }),
                                              order: Array(0..<n), viewport: viewport, offset: CGFloat(offset), focused: focused, nextID: n)
                            world.offset = CGFloat(offset)
                            frontier.insert(world)
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
                    let after = apply(step, world, settle: settle)
                    transitions += 1
                    let bad = check(step, before: world, after: after, settle: settle)
                    if !bad.isEmpty, violations.count < 5 { violations.append("\(world.order) h\(world.heights) vp\(world.viewport) off\(world.offset) f\(String(describing: world.focused)) \(step): \(bad)") }
                    if seen.insert(after).inserted { next.insert(after) }
                }
            }
            frontier = next
        }
        return (seen.count, transitions, violations)
    }

    @Test func everyReachableListStateKeepsTheViewportRules() {
        let result = Self.explore(depth: 3, settle: Self.real)
        #expect(result.violations.isEmpty, "\(result.violations)")
        #expect(result.states > 10_000)
        print("ListViewport: \(result.states) states, \(result.transitions) transitions")
    }

    @Test(arguments: ["noAnchor", "noReveal", "centerReveal", "noClamp", "alwaysRevealTop", "revealTwice"])
    func mutantIsCaught(_ name: String) {
        let mutant: Settle = { new, old, offset, focused, newFocus in
            let real = new.settle(from: old, offset: offset, focused: focused, newFocus: newFocus, padding: Self.padding)
            switch name {
            case "noAnchor":
                // The old sidebar: the offset stays in content space.
                guard let f = newFocus, let item = new.item(f), f != focused else { return new.clamp(offset) }
                return new.reveal(item, from: offset, padding: Self.padding)
            case "noReveal":
                return new.anchored(from: old, offset: offset, focused: focused)
            case "centerReveal":
                guard let f = newFocus, f != focused, let item = new.item(f) else { return real }
                return new.clamp(item.start + item.length / 2 - new.viewport / 2)
            case "noClamp":
                return real - 1
            case "alwaysRevealTop":
                // Also breaks the edge rule: a row in view is re-aligned.
                guard let f = newFocus, let item = new.item(f) else { return real }
                return new.clamp(item.start - Self.padding)
            case "revealTwice":
                // A second scroll after settle: a different target when settled again.
                return real == 0 ? real : real - 1
            default:
                return real
            }
        }
        let result = Self.explore(depth: 2, settle: mutant)
        #expect(!result.violations.isEmpty, "mutant \(name) not caught")
    }
}
