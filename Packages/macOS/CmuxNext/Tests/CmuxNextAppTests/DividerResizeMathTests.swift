import AppKit
@testable import CmuxNextLayout
import Testing

/// The pure math behind modifier drags (plans/cmux-next/resize-modifiers.md): which keys mean
/// which mode, Option's push across a column's splits, Option's trade and Command's uniform width
/// across the strip.
struct DividerResizeMathTests {
    @Test func keysPickModes() {
        let cases: [(NSEvent.ModifierFlags, DividerDragModifiers)] = [
            (.option, DividerDragModifiers(push: true)),
            (.command, DividerDragModifiers(all: true)),
            ([.command, .option], DividerDragModifiers(all: true)),
            (.shift, DividerDragModifiers(snap: true)),
            (.control, DividerDragModifiers(fine: true)),
            ([.option, .shift], DividerDragModifiers(push: true, snap: true)),
            ([.capsLock, .function], DividerDragModifiers()),
        ]
        for (flags, modes) in cases { #expect(DividerDragModifiers(flags) == modes, "\(flags.rawValue)") }
    }

    static func divider(_ id: SplitID, container: CGRect, leading: CGFloat, minimumA: CGFloat = 100) -> DividerGeometry {
        DividerGeometry(id: id, axis: .horizontal, frame: CGRect(x: container.minX + leading, y: 0, width: 1, height: 100),
                        hitFrame: .zero, container: container, minimumA: minimumA, minimumB: 100)
    }

    /// p1 | (p2 | p3) in a 601 pt column: dragging the inner divider 50 pt right with Option grows
    /// p2 by 50 and the column by 50; p1 and p3 keep their widths.
    @Test func pushGrowsOnlyThePaneBeforeTheDivider() throws {
        let tree: SplitNode = .split("x", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                     b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))
        let column = LayoutColumn(id: "c", width: 0.5, root: tree)
        let outer = CGRect(x: 0, y: 0, width: 601, height: 100), inner = CGRect(x: 201, y: 0, width: 400, height: 100)
        let dividers = [Self.divider("x", container: outer, leading: 200), Self.divider("y", container: inner, leading: 199.5)]
        let push = try #require(PushResize(split: "y", column: column, columnWidth: 601, dividers: dividers, viewport: 2000,
                                           gap: 0, dividerThickness: 1))
        var ratios: [SplitID: Double] = [:]
        var width: Double?
        for target in push.targets(delta: 50) {
            switch target {
            case let .ratio(split, ratio): ratios[split] = ratio
            case let .width(_, share): width = share
            }
        }
        #expect(abs((try #require(width)) * 2000 - 651) < 0.01)
        let x = try #require(ratios["x"]), y = try #require(ratios["y"])
        let p1 = x * 650, p2 = y * (650 - 200 - 1), p3 = (1 - y) * 449
        #expect(abs(p1 - 200) < 0.01)
        #expect(abs(p2 - 249.5) < 0.01)
        #expect(abs(p3 - 199.5) < 0.01)
    }

    @Test func pushStopsAtThePaneMinimum() throws {
        let column = LayoutColumn(id: "c", width: 0.5, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))
        let container = CGRect(x: 0, y: 0, width: 401, height: 100)
        let push = try #require(PushResize(split: "x", column: column, columnWidth: 401,
                                           dividers: [Self.divider("x", container: container, leading: 200, minimumA: 150)],
                                           viewport: 2000, gap: 0, dividerThickness: 1))
        let widths = push.targets(delta: -500).compactMap { if case let .width(_, w) = $0 { w } else { nil } }
        #expect(abs((widths.first ?? 0) * 2000 - 351) < 0.01)
    }

    @Test func aVerticalDividerOrADockedColumnDoesNotPush() {
        let vertical = LayoutColumn(id: "c", root: .split("x", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))
        let divider = Self.divider("x", container: CGRect(x: 0, y: 0, width: 400, height: 400), leading: 200)
        #expect(PushResize(split: "x", column: vertical, columnWidth: 400, dividers: [divider], viewport: 2000, gap: 0,
                           dividerThickness: 1) == nil)
        var docked = LayoutColumn(id: "c", root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))
        docked.dock = DockColumn(edge: .right)
        #expect(PushResize(split: "x", column: docked, columnWidth: 400, dividers: [divider], viewport: 2000, gap: 0,
                           dividerThickness: 1) == nil)
    }

    static let strip = StripStart(columns: [
        .init(id: "a", width: 0.4, minimum: 200), .init(id: "b", width: 0.3, minimum: 200), .init(id: "c", width: 0.3, minimum: 200),
    ], viewport: 1000, gap: 0)

    /// The widths `targets` set, by column, rounded to a thousandth.
    static func widths(_ targets: [DividerDragValue]) -> [ColumnID: Double] {
        Dictionary(uniqueKeysWithValues: targets.compactMap {
            if case let .width(column, width) = $0 { (column, (width * 1000).rounded() / 1000) } else { nil }
        })
    }

    @Test func tradeMovesWidthBetweenNeighborsAndKeepsTheRest() {
        #expect(Self.widths(Self.strip.trading("a", to: 0.45)) == ["a": 0.45, "b": 0.25])
        // b may give up only down to its 200 pt minimum.
        #expect(Self.widths(Self.strip.trading("a", to: 0.8)) == ["a": 0.5, "b": 0.2])
        // The last column has no neighbor to trade with.
        #expect(Self.widths(Self.strip.trading("c", to: 0.5)) == ["c": 0.5])
    }

    @Test func uniformGivesEveryColumnOneWidthAtLeastTheWidestMinimum() {
        #expect(Self.widths(Self.strip.uniform(0.35)) == ["a": 0.35, "b": 0.35, "c": 0.35])
        #expect(Self.widths(Self.strip.uniform(0.1)) == ["a": 0.2, "b": 0.2, "c": 0.2])
    }
}
