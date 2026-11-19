@testable import CmuxNextDaemon
import Testing

/// The screen's tree index (``LayoutIndex``) answers what the overlay's walks answered (the first leaf or stack
/// showing a pane, a split's place, whether the tree shows a pane), so an intent's lookups cost the target's depth and
/// not the screen: the overlay bench's find, `leaf_placed`, `target_index` and New Column's span grew to 36, 51 and
/// 69 us of a 250 us intend at 256 panes. The screen keeps it with every tree write and puts it back with a split's undo.
@MainActor @Suite struct LayoutIndexTests {
    private static func leaf(_ pane: UInt64) -> LayoutNode { .leaf(PaneID(rawValue: pane)) }

    private static func split(_ id: UInt64?, _ a: LayoutNode, _ b: LayoutNode) -> LayoutNode {
        .split(id: id.map(SplitID.init(rawValue:)), resourceID: nil, direction: .right, ratio: 0.5, a: a, b: b)
    }

    private static func chain(_ count: UInt64) -> LayoutNode {
        var node = leaf(count)
        for pane in stride(from: count - 1, through: 1, by: -1) { node = split(1000 + pane, leaf(pane), node) }
        return node
    }

    /// A mixed tree: leaves, a stack, a split with no daemon handle.
    private static let mixed: LayoutNode = split(1, split(2, leaf(1), .stack(panes: [PaneID(rawValue: 2), PaneID(rawValue: 3)],
                                                                                  expanded: PaneID(rawValue: 3))),
                                                split(nil, split(4, leaf(4), split(5, leaf(5), leaf(6))), split(3, leaf(10), leaf(11))))

    /// The index agrees with the walks for every pane and split the tree names, and for one it does not.
    private static func expectAgrees(_ index: LayoutIndex, _ tree: LayoutNode, panes: [UInt64], splits: [UInt64],
                                     sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(index.exact, sourceLocation: sourceLocation)
        for raw in panes + [999] {
            let pane = PaneID(rawValue: raw)
            #expect(index.contains(pane: pane) == tree.contains(pane: pane), "pane \(raw)", sourceLocation: sourceLocation)
            guard let path = index.panes[pane] else { continue }
            switch tree.node(at: path[...]) {
            case .leaf(let shown)?: #expect(shown == pane, sourceLocation: sourceLocation)
            case .stack(let stacked, _)?: #expect(stacked.contains(pane), sourceLocation: sourceLocation)
            default: Issue.record("pane \(raw)'s path names no leaf or stack", sourceLocation: sourceLocation)
            }
        }
        for raw in splits {
            guard let path = index.splits[SplitID(rawValue: raw)], case .split(let id, _, _, _, _, _)? = tree.node(at: path[...]) else {
                Issue.record("split \(raw) not indexed", sourceLocation: sourceLocation)
                continue
            }
            #expect(id == SplitID(rawValue: raw), sourceLocation: sourceLocation)
        }
    }

    @Test func indexAgreesWithTheWalks() {
        Self.expectAgrees(LayoutIndex(Self.mixed), Self.mixed, panes: [1, 2, 3, 4, 5, 6, 10, 11], splits: [1, 2, 3, 4, 5])
        let chain = Self.chain(256)
        Self.expectAgrees(LayoutIndex(chain), chain, panes: Array(1...256), splits: Array(1001...1255))
    }

    @Test func aPaneShownTwiceMakesTheIndexInexact() {
        #expect(!LayoutIndex(Self.split(1, Self.leaf(1), Self.leaf(1))).exact)
        #expect(!LayoutIndex(Self.split(1, Self.split(1, Self.leaf(1), Self.leaf(2)), Self.leaf(3))).exact)
    }

    /// A split's splice edits the index in place and leaves it equal to one built from the new tree.
    @Test func replaceEqualsARebuild() {
        let tree = Self.chain(64)
        var index = LayoutIndex(tree)
        let path = index.panes[PaneID(rawValue: 64)] ?? []
        let new = Self.split(nil, Self.leaf(64), Self.leaf(500))
        index.replace(at: path, old: Self.leaf(64), new: new)
        let spliced = tree.splicing(at: path[...], with: new) ?? tree
        let rebuilt = LayoutIndex(spliced)
        #expect(index.panes == rebuilt.panes)
        #expect(index.splits == rebuilt.splits)
        // Wrapping a split whole moves its subtree one step down.
        let around = index.splits[SplitID(rawValue: 1060)] ?? []
        let held = spliced.node(at: around[...]) ?? Self.leaf(0)
        let wrapped = Self.split(nil, Self.leaf(501), held)
        index.replace(at: around, old: held, new: wrapped)
        let rewrapped = LayoutIndex(spliced.splicing(at: around[...], with: wrapped) ?? spliced)
        #expect(index.panes == rewrapped.panes)
        #expect(index.splits == rewrapped.splits)
    }

    /// A screen keeps the index with an overlay split, and its undo puts back the index and slots it replaced; a write
    /// in between makes the undo build them again instead.
    @Test func screenKeepsTheIndexAcrossASplitAndItsUndo() {
        let panes = (1...64).map { PaneSnapshot(id: PaneID(rawValue: UInt64($0)), tabs: []) }
        let screen = ScreenModel(ScreenSnapshot(id: ScreenID(rawValue: 1), layout: Self.chain(64), panes: panes))
        let before = screen.layout
        let target = screen.panes[63]
        #expect(screen.slot(of: target) == 63)
        let path = screen.layoutIndex()?.panes[PaneID(rawValue: 64)] ?? []
        let new = Self.split(nil, Self.leaf(64), Self.leaf(500))
        let shown = before.splicing(at: path[...], with: new) ?? before
        let pane = PaneModel(PaneSnapshot(id: PaneID(rawValue: 500), tabs: []))
        screen.showSplit(layout: shown, change: .splice(path: path, old: Self.leaf(64), new: new), columns: nil, pane: pane, at: 64)
        #expect(screen.layoutIndex()?.panes == LayoutIndex(shown).panes)
        #expect(screen.slot(of: pane) == 64)
        screen.undoSplit(layout: before, columns: [], pane: pane)
        #expect(screen.layout == before)
        #expect(screen.panes.count == 64)
        #expect(screen.layoutIndex()?.panes == LayoutIndex(before).panes)
        #expect(screen.slot(of: pane) == nil)
        #expect(screen.slot(of: target) == 63)

        // A daemon write between the split and its undo: the undo keeps nothing stale.
        screen.showSplit(layout: shown, change: .splice(path: path, old: Self.leaf(64), new: new), columns: nil, pane: pane, at: 0)
        screen.layout = Self.chain(3)
        screen.undoSplit(layout: before, columns: [], pane: pane)
        #expect(screen.layoutIndex()?.panes == LayoutIndex(before).panes)
        #expect(screen.slot(of: target) == 63)
    }
}
