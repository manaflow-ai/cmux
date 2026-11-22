import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A pane-edge drop's target draws the layout that lands, pane for pane: the new pane's fill and
/// every pane the drop resizes or moves outlined at its final frame. Each drop lands as the App
/// lands it: the ratio intents the drop sends once its move echoed (`AppServices.splitSizing`),
/// and the daemon's tree (the emptied pane gone, the target split at 0.5) through
/// `LayoutModel.apply`, which sends the close sizing of the emptied pane. Both orders. Before,
/// the target left that close sizing out: A|B|C with B's only tab dropped on A's bottom edge drew
/// A over the new pane at a third and C at two thirds, and the panes landed at halves.
@MainActor
@Suite(.closesItsWindows)
struct DropPreviewLandingParityTests {
    nonisolated static let layouts: [(name: String, root: SplitNode)] = [
        ("a|b|c", .split("x", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"),
                         b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c")))),
        ("a/b/c", .split("x", axis: .vertical, ratio: 1.0 / 3, a: .leaf("a"),
                         b: .split("y", axis: .vertical, ratio: 0.5, a: .leaf("b"), b: .leaf("c")))),
        ("(a|b)/c", .split("x", axis: .vertical, ratio: 0.5, a: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b")),
                           b: .leaf("c"))),
        ("a|(b/c)", .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("a"),
                           b: .split("y", axis: .vertical, ratio: 0.5, a: .leaf("b"), b: .leaf("c")))),
        ("(a/b)|(c/d)", .split("x", axis: .horizontal, ratio: 0.5, a: .split("y", axis: .vertical, ratio: 0.5, a: .leaf("a"), b: .leaf("b")),
                               b: .split("z", axis: .vertical, ratio: 0.5, a: .leaf("c"), b: .leaf("d")))),
        ("a|b|(c/d)", .split("x", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"),
                             b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("b"),
                                       b: .split("z", axis: .vertical, ratio: 0.5, a: .leaf("c"), b: .leaf("d"))))),
    ]

    @Test(arguments: DropPreviewLandingParityTests.layouts.indices)
    func everyEdgeDropLandsWhereItsTargetDrewIt(_ index: Int) throws {
        let (name, root) = Self.layouts[index]
        let window = Window(root)
        defer { window.window.closeAfterTest() }
        let view = try #require(window.root.screenViews["s"])
        var checked = 0
        for target in root.panes {
            for zone in [PaneDropZone.left, .right, .top, .bottom] {
                // nil: the dragged tab's pane keeps a tab; else that pane's only tab, its pane closes.
                let removals: [PaneID?] = [nil] + root.panes.filter { $0 != target }.map { Optional($0) }
                for removing in removals {
                    let label = "\(name): \(removing.map { "\($0.rawValue)'s only tab" } ?? "a tab") on \(target.rawValue) \(zone)"
                    guard let drawn = Self.drawnTarget(view, pane: target, zone: zone, removing: removing) else { continue }
                    for order in [Order.sizingFirst, .treeFirst] {
                        let landed = Self.land(root, pane: target, zone: zone, removing: removing, order: order, in: view)
                        let newPane = try #require(landed[Self.newPane], "\(label): no new pane")
                        #expect(Self.same(drawn.newPane, newPane), "\(label), \(order): new pane drawn \(drawn.newPane), landed \(newPane)")
                        let before = view.geometry.panes.mapValues { Self.shown($0, in: view) }
                        let moved = landed.filter { $0.key != Self.newPane && !Self.same($0.value, before[$0.key] ?? .null) }
                        #expect(moved.count == drawn.companions.count,
                                "\(label), \(order): \(drawn.companions.count) panes outlined, \(moved.count) moved")
                        for (pane, frame) in moved {
                            #expect(drawn.companions.contains { Self.same($0, frame) },
                                    "\(label), \(order): \(pane.rawValue) landed at \(frame), outlines \(drawn.companions)")
                        }
                    }
                    checked += 1
                }
            }
        }
        #expect(checked > 0, "\(name): no edge drop was a split target")
    }

    // MARK: Drop

    enum Order { case sizingFirst, treeFirst }

    static let newPane = PaneID(rawValue: "n")

    /// The target `ScreenContentView.dropTarget` draws for a drag held on `zone` of `pane` (nil when
    /// the room rule makes it something other than that split).
    static func drawnTarget(_ view: ScreenContentView, pane: PaneID, zone: PaneDropZone,
                            removing: PaneID?) -> (newPane: CGRect, companions: [CGRect])? {
        let (headers, footers) = view.paneChromeBands()
        guard let body = view.paneBody(pane, headers: headers, footers: footers) else { return nil }
        let point = switch zone {
        case .left: CGPoint(x: body.minX + 6, y: body.midY)
        case .right: CGPoint(x: body.maxX - 6, y: body.midY)
        case .top: CGPoint(x: body.midX, y: body.minY + 6)
        case .bottom: CGPoint(x: body.midX, y: body.maxY - 6)
        case .center: CGPoint(x: body.midX, y: body.midY)
        }
        guard let hit = view.dropTarget(at: point, removing: removing), hit.target == .pane(pane, zone) else { return nil }
        return (hit.highlight, hit.companions)
    }

    /// The pane frames (content, inset 2 pt, as the target draws them) once the drop landed in `order`.
    static func land(_ root: SplitNode, pane: PaneID, zone: PaneDropZone, removing: PaneID?, order: Order,
                     in view: ScreenContentView) -> [PaneID: CGRect] {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(root))], activeScreenID: "s", focusedPane: pane)
        model.splitSizingOverride = .even
        // What the App sends once the move echoed (AppServices.splitSizing), computed before the move.
        let sizing = model.dropSizingChanges(splitting: pane, zone: zone, removing: removing)
        let tree = LayoutScreen(id: "s", name: "s", layout: .splits(daemonMove(root, pane: pane, zone: zone, removing: removing)))
        switch order {
        case .sizingFirst:
            model.applySplitSizing(sizing)
            model.apply(screens: [tree])
        case .treeFirst:
            model.apply(screens: [tree])
            model.applySplitSizing(sizing)
        }
        return frames(model.screens[0].layout, in: view)
    }

    /// cmux-tui's `move-tab-to-split`: the target splits at 0.5 with the new pane on the zone's
    /// side, the emptied pane leaves (its sibling takes its parent's place), every ratio kept.
    static func daemonMove(_ root: SplitNode, pane: PaneID, zone: PaneDropZone, removing: PaneID?) -> SplitNode {
        let axis: SplitAxis = zone == .left || zone == .right ? .horizontal : .vertical
        let first = zone == .left || zone == .top
        let split = root.replacingLeaf(pane) { leaf in
            .split("n-split", axis: axis, ratio: 0.5, a: first ? .leaf(newPane) : leaf, b: first ? leaf : .leaf(newPane))
        }
        return removing.flatMap { split.removing($0) } ?? split
    }

    static func frames(_ layout: ScreenLayout, in view: ScreenContentView) -> [PaneID: CGRect] {
        let geometry = ScreenGeometry.compute(layout, viewport: view.bounds.size, style: view.context.style,
                                              scale: view.window?.backingScaleFactor ?? 2)
        return geometry.panes.mapValues { shown($0, in: view) }
    }

    /// A pane cell as the target draws it: its content rect, inset 2 pt.
    static func shown(_ cell: CGRect, in view: ScreenContentView) -> CGRect {
        PaneChromeGeometry.contentRect(forCell: cell, style: view.context.style).insetBy(dx: 2, dy: 2)
    }

    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height) < 1
    }

    // MARK: Harness

    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Window {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 1000), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        init(_ tree: SplitNode) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s",
                                focusedPane: tree.panes.first)
            model.splitSizingOverride = .even
            root = LayoutRootView(model: model, contentProvider: provider)
            window.contentView = root
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
        }
    }
}
