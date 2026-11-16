import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// The focus keys with floating panes (`FocusNavigation.neighbor` with `floating`): a key reaches a floating pane
/// that stands between 2 tiled panes and the same key leaves it, so a floating pane never traps the focus; a tiled
/// pane that a floating pane covers wholly never gets the focus.
///
/// The property test makes grids of 1 to 4 columns and 1 to 3 rows with 1 to 3 floating panes, from a fixed seed.
/// It does not make docked columns or a scroll strip, and its focus history has 2 entries.
@MainActor struct FloatingPaneFocusRuleTests {
    let a: PaneID = "a", b: PaneID = "b", c: PaneID = "c", f: PaneID = "f"

    func next(_ pane: PaneID, _ direction: LayoutDirection, _ frames: [PaneID: CGRect], recency: [PaneID], floating: [PaneID]) -> PaneID? {
        FocusNavigation.neighbor(of: pane, direction: direction, frames: frames, recency: recency, floating: floating)
    }

    @Test func aKeyReachesAFloatingPaneBetweenTwoTiledPanesAndLeavesIt() {
        let frames: [PaneID: CGRect] = [
            a: CGRect(x: 0, y: 0, width: 600, height: 900), b: CGRect(x: 600, y: 0, width: 600, height: 900),
            f: CGRect(x: 450, y: 300, width: 300, height: 300),
        ]
        #expect(next(a, .right, frames, recency: [a], floating: [f]) == f)
        #expect(next(f, .right, frames, recency: [f, a], floating: [f]) == b, "the same key goes on to the tiled target")
        #expect(next(f, .left, frames, recency: [f, a], floating: [f]) == a, "the opposite key goes back")
        #expect(next(b, .left, frames, recency: [b, f, a], floating: [f]) == f)
        #expect(next(f, .left, frames, recency: [f, b, a], floating: [f]) == a)
        #expect(next(a, .left, frames, recency: [a], floating: [f]) == nil)
        // With no floating pane the tiled rule is the whole rule.
        #expect(next(a, .right, frames.filter { $0.key != f }, recency: [a], floating: []) == b)
        #expect(next(a, .right, frames.filter { $0.key != f }, recency: [a], floating: [f]) == b, "a floating pane with no frame is not there")
    }

    @Test func aTiledPaneThatAFloatingPaneCoversWhollyNeverGetsTheFocus() {
        let frames: [PaneID: CGRect] = [
            a: CGRect(x: 0, y: 0, width: 400, height: 900), b: CGRect(x: 400, y: 0, width: 400, height: 900),
            c: CGRect(x: 800, y: 0, width: 400, height: 900), f: CGRect(x: 390, y: 0, width: 420, height: 900),
        ]
        #expect(next(a, .right, frames, recency: [a], floating: [f]) == f)
        #expect(next(f, .right, frames, recency: [f, a], floating: [f]) == c, "not the covered pane")
        #expect(next(c, .left, frames, recency: [c, f, a], floating: [f]) == f)
        #expect(next(f, .left, frames, recency: [f, c, a], floating: [f]) == a)
        #expect(next(f, .left, frames, recency: [f, a], floating: [f]) == a)
    }

    @Test func twoFloatingPanesInARowAreTwoStops() {
        let g: PaneID = "g"
        let frames: [PaneID: CGRect] = [
            a: CGRect(x: 0, y: 0, width: 600, height: 900), b: CGRect(x: 600, y: 0, width: 600, height: 900),
            f: CGRect(x: 300, y: 300, width: 200, height: 200), g: CGRect(x: 520, y: 300, width: 200, height: 200),
        ]
        #expect(next(a, .right, frames, recency: [a], floating: [f, g]) == f)
        #expect(next(f, .right, frames, recency: [f, a], floating: [f, g]) == g)
        #expect(next(g, .right, frames, recency: [g, f, a], floating: [f, g]) == b)
        #expect(next(g, .left, frames, recency: [g, f, a], floating: [f, g]) == f)
    }

    /// A generator with a fixed seed: the same layouts at each run.
    struct Generator {
        var state: UInt64
        mutating func below(_ bound: UInt64) -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (state >> 33) % bound
        }
        mutating func unit() -> CGFloat { CGFloat(below(10001)) / 10000 }
    }

    struct Layout {
        var frames: [PaneID: CGRect] = [:]
        var tiled: [PaneID] = []
        var floating: [PaneID] = []
    }

    static func layout(_ generator: inout Generator, allowsCover: Bool) -> Layout {
        let width: CGFloat = 1200, height: CGFloat = 900
        let columns = 1 + Int(generator.below(4)), rows = 1 + Int(generator.below(3))
        var layout = Layout()
        for column in 0..<columns {
            for row in 0..<rows {
                let pane = PaneID(rawValue: "t\(column)\(row)")
                layout.tiled.append(pane)
                layout.frames[pane] = CGRect(x: CGFloat(column) * width / CGFloat(columns), y: CGFloat(row) * height / CGFloat(rows),
                                             width: width / CGFloat(columns), height: height / CGFloat(rows))
            }
        }
        for index in 0..<(1 + Int(generator.below(3))) {
            let w = (0.15 + generator.unit() * 0.6) * width, h = (0.15 + generator.unit() * 0.6) * height
            let frame = CGRect(x: generator.unit() * (width - w), y: generator.unit() * (height - h), width: w, height: h)
            if !allowsCover, layout.tiled.contains(where: { frame.contains(layout.frames[$0] ?? .zero) }) { continue }
            let pane = PaneID(rawValue: "f\(index)")
            layout.frames[pane] = frame
            layout.floating.append(pane)
        }
        return layout
    }

    struct Place: Hashable {
        var focus: PaneID
        var origin: PaneID
    }

    /// Each problem of `layout`, by a walk over each (focus, tiled pane before it) that the keys can make from each
    /// tiled pane that shows.
    static func problems(of layout: Layout) -> [String] {
        let floating = Set(layout.floating)
        let covered = Set(layout.tiled.filter { pane in
            layout.floating.contains { layout.frames[$0]?.contains(layout.frames[pane] ?? .zero) ?? false }
        })
        let wanted = Set(layout.frames.keys).subtracting(covered)
        var problems: [String] = []
        for start in layout.tiled where !covered.contains(start) {
            var seen: Set<Place> = [Place(focus: start, origin: start)], queue = [Place(focus: start, origin: start)]
            var reached: Set<PaneID> = [start]
            while let place = queue.popLast() {
                let recency = floating.contains(place.focus) ? [place.focus, place.origin] : [place.focus]
                for direction in [LayoutDirection.left, .right, .up, .down] {
                    guard let found = FocusNavigation.neighbor(of: place.focus, direction: direction, frames: layout.frames,
                                                               recency: recency, floating: layout.floating) else { continue }
                    if found == place.focus || layout.frames[found] == nil {
                        problems.append("\(place.focus) \(direction): \(found) is not another pane")
                        continue
                    }
                    if covered.contains(found) {
                        problems.append("\(place.focus) \(direction): \(found) does not show")
                        continue
                    }
                    reached.insert(found)
                    let origin = !floating.contains(found) ? found : floating.contains(place.focus) ? place.origin : place.focus
                    if seen.insert(Place(focus: found, origin: origin)).inserted { queue.append(Place(focus: found, origin: origin)) }
                }
            }
            if reached != wanted { problems.append("from \(start): no keys reach \(wanted.subtracting(reached).sorted())") }
        }
        return problems
    }

    /// From each pane each key gives another pane that shows, or nothing; and from each tiled pane that shows, a
    /// finite count of keys reaches each floating pane and each other tiled pane that shows.
    @Test(arguments: [false, true])
    func theKeysReachEachPaneThatShowsAndNoPaneThatDoesNot(allowsCover: Bool) {
        var generator = Generator(state: 0x5_EEDF_10A7)
        var checked = 0, failures: [String] = []
        for index in 0..<2000 {
            let layout = Self.layout(&generator, allowsCover: allowsCover)
            guard !layout.floating.isEmpty else { continue }
            checked += 1
            let problems = Self.problems(of: layout)
            if !problems.isEmpty, failures.count < 3 {
                failures.append("layout \(index): \(problems.prefix(3)) \(layout.frames.sorted { $0.key < $1.key })")
            }
        }
        #expect(checked > 1000, "the generator made layouts with a floating pane")
        #expect(failures.isEmpty, "\(failures)")
    }
}
