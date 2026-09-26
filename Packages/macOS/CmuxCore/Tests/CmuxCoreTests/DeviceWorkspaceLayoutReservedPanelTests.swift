import CmuxCore
import Foundation
import Testing

@Suite("Reserved panels in Mac device workspace layouts")
struct DeviceWorkspaceLayoutReservedPanelTests {
    @Test func removingReservedPanelsGivesEmptiedPanesSpaceToTheirSibling() {
        let local = DeviceWorkspaceLayoutNode.split(direction: .horizontal, ratio: 0.3,
            first: .pane(id: "left", surfaceIDs: ["a", "reserved-1"], selectedSurfaceID: "reserved-1"),
            second: .pane(id: "right", surfaceIDs: ["reserved-2"], selectedSurfaceID: "reserved-2"))
        #expect(local.removingSurfaceIDs(["reserved-1", "reserved-2"])
            == .pane(id: "left", surfaceIDs: ["a"], selectedSurfaceID: nil))
        #expect(local.removingSurfaceIDs(["a", "reserved-1", "reserved-2"]) == nil)
        #expect(local.removingSurfaceIDs([]) == local)
    }

    @Test func restoresReservedTabsBesideTheirLocalNeighbors() {
        let local = DeviceWorkspaceLayoutNode.pane(id: "p", surfaceIDs: ["lead", "a", "tab-1", "tab-2", "b"], selectedSurfaceID: "a")
        let owner = DeviceWorkspaceLayoutNode.split(direction: .vertical, ratio: 0.5,
            first: .pane(id: "top", surfaceIDs: ["b", "x"], selectedSurfaceID: "b"),
            second: .pane(id: "bottom", surfaceIDs: ["a"], selectedSurfaceID: "a"))
        let restored = owner.grafting(["lead", "tab-1", "tab-2"], from: local)
        // "lead" has no placed tab before it, so it goes before the next one.
        #expect(restored == .split(direction: .vertical, ratio: 0.5,
            first: .pane(id: "top", surfaceIDs: ["b", "x"], selectedSurfaceID: "b"),
            second: .pane(id: "bottom", surfaceIDs: ["lead", "a", "tab-1", "tab-2"], selectedSurfaceID: "a")))
    }

    @Test func restoresAReservedSplitAroundTheTerminalsItDivided() {
        let reserved = DeviceWorkspaceLayoutNode.pane(id: "reserved", surfaceIDs: ["new"], selectedSurfaceID: "new")
        let local = DeviceWorkspaceLayoutNode.split(direction: .horizontal, ratio: 0.5,
            first: .pane(id: "left", surfaceIDs: ["a"], selectedSurfaceID: "a"),
            second: .split(direction: .vertical, ratio: 0.7, first: reserved,
                second: .pane(id: "right", surfaceIDs: ["b", "c"], selectedSurfaceID: "b")))
        let owner = DeviceWorkspaceLayoutNode.split(direction: .horizontal, ratio: 0.4,
            first: .pane(id: "owner-left", surfaceIDs: ["a"], selectedSurfaceID: "a"),
            second: .pane(id: "owner-right", surfaceIDs: ["b", "c"], selectedSurfaceID: "c"))
        let restored = owner.grafting(["new"], from: local)
        #expect(restored == .split(direction: .horizontal, ratio: 0.4,
            first: .pane(id: "owner-left", surfaceIDs: ["a"], selectedSurfaceID: "a"),
            second: .split(direction: .vertical, ratio: 0.7, first: reserved,
                second: .pane(id: "owner-right", surfaceIDs: ["b", "c"], selectedSurfaceID: "c"))))
    }

    @Test func splitGraftWrapsTheSmallestSubtreeHoldingEveryDividedTerminal() {
        let reserved = DeviceWorkspaceLayoutNode.pane(id: "reserved", surfaceIDs: ["new"], selectedSurfaceID: nil)
        let local = DeviceWorkspaceLayoutNode.split(direction: .vertical, ratio: 0.25,
            first: .pane(id: "p", surfaceIDs: ["b", "c"], selectedSurfaceID: nil), second: reserved)
        let divided = DeviceWorkspaceLayoutNode.split(direction: .horizontal, ratio: 0.6,
            first: .pane(id: "b", surfaceIDs: ["b"], selectedSurfaceID: nil),
            second: .pane(id: "c", surfaceIDs: ["c"], selectedSurfaceID: nil))
        let owner = DeviceWorkspaceLayoutNode.split(direction: .vertical, ratio: 0.5,
            first: .pane(id: "a", surfaceIDs: ["a"], selectedSurfaceID: nil), second: divided)
        #expect(owner.grafting(["new"], from: local) == .split(direction: .vertical, ratio: 0.5,
            first: .pane(id: "a", surfaceIDs: ["a"], selectedSurfaceID: nil),
            second: .split(direction: .vertical, ratio: 0.25, first: divided, second: reserved)))
    }

    @Test func strandedPanelsGoLastInLocalOrderThenSorted() {
        let local = DeviceWorkspaceLayoutNode.split(direction: .horizontal, ratio: 0.5,
            first: .pane(id: "p1", surfaceIDs: ["k2", "k1"], selectedSurfaceID: nil),
            second: .pane(id: "p2", surfaceIDs: ["gone"], selectedSurfaceID: nil))
        let owner = DeviceWorkspaceLayoutNode.split(direction: .vertical, ratio: 0.5,
            first: .pane(id: "o1", surfaceIDs: ["a"], selectedSurfaceID: "a"),
            second: .pane(id: "o2", surfaceIDs: [], selectedSurfaceID: nil))
        #expect(owner.grafting(["unknown-b", "k1", "unknown-a", "k2"], from: local) == .split(direction: .vertical, ratio: 0.5,
            first: .pane(id: "o1", surfaceIDs: ["a", "k2", "k1", "unknown-a", "unknown-b"], selectedSurfaceID: "a"),
            second: .pane(id: "o2", surfaceIDs: [], selectedSurfaceID: nil)))
        let empty = DeviceWorkspaceLayoutNode.pane(id: "empty", surfaceIDs: [], selectedSurfaceID: nil)
        #expect(empty.grafting(["k1"], from: local) == empty)
    }

    /// The indexed graft places panels exactly where one full-tree insert per
    /// panel placed them.
    @Test func matchesPerPanelInsertion() {
        for seed in 0..<3_000 {
            var random = SplitMix64(seed: UInt64(seed))
            var nextID = 0
            let local = RandomLayout.tree(depth: 4, random: &random, nextID: &nextID, prefix: "s")
            let localIDs = local.referenceOrderedSurfaceIDs
            var kept = Set(localIDs.filter { _ in random.chance(0.35) })
            if random.chance(0.2) { kept.insert("unknown-\(seed)") }
            let owner: DeviceWorkspaceLayoutNode
            if random.chance(0.5), let trimmed = local.removingSurfaceIDs(kept) {
                owner = trimmed
            } else {
                var survivors = localIDs.filter { !kept.contains($0) && !random.chance(0.15) }
                survivors += (0..<Int(random.next() % 3)).map { "mac-\($0)" }
                survivors.shuffle(using: &random)
                owner = RandomLayout.tree(arranging: survivors[...], random: &random, paneID: "o")
            }
            let expected = owner.referenceGrafting(kept, from: local)
            let actual = owner.grafting(kept, from: local)
            #expect(actual == expected, "seed \(seed)")
            if actual != expected { return }
        }
    }

    @Test func graftingRestoresLargeLayouts() {
        let count = 40_000
        let localIDs = (0..<count).map { "s\($0)" }
        let kept = Set(localIDs.enumerated().filter { $0.offset % 2 == 1 }.map(\.element))
        let local = DeviceWorkspaceLayoutNode.pane(id: "p", surfaceIDs: localIDs, selectedSurfaceID: nil)
        let owner = DeviceWorkspaceLayoutNode.pane(id: "o", surfaceIDs: localIDs.filter { !kept.contains($0) }, selectedSurfaceID: nil)
        let restored = owner.grafting(kept, from: local)
        #expect(restored == .pane(id: "o", surfaceIDs: localIDs, selectedSurfaceID: nil))
    }
}

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func chance(_ probability: Double) -> Bool {
        Double(next() % 1_000) < probability * 1_000
    }
}

private enum RandomLayout {
    static func tree(depth: Int, random: inout SplitMix64, nextID: inout Int, prefix: String) -> DeviceWorkspaceLayoutNode {
        if depth == 0 || random.chance(0.35) {
            let surfaces = (0..<(1 + Int(random.next() % 4))).map { _ -> String in
                defer { nextID += 1 }
                return "\(prefix)\(nextID)"
            }
            return .pane(id: "pane-\(prefix)\(nextID)", surfaceIDs: surfaces, selectedSurfaceID: surfaces.randomElement(using: &random))
        }
        return .split(direction: random.chance(0.5) ? .horizontal : .vertical, ratio: 0.3,
            first: tree(depth: depth - 1, random: &random, nextID: &nextID, prefix: prefix),
            second: tree(depth: depth - 1, random: &random, nextID: &nextID, prefix: prefix))
    }

    static func tree(arranging surfaces: ArraySlice<String>, random: inout SplitMix64, paneID: String) -> DeviceWorkspaceLayoutNode {
        if surfaces.count <= 1 || random.chance(0.3) {
            return .pane(id: paneID, surfaceIDs: Array(surfaces), selectedSurfaceID: surfaces.first)
        }
        let cut = surfaces.startIndex + 1 + Int(random.next() % UInt64(surfaces.count - 1))
        return .split(direction: random.chance(0.5) ? .horizontal : .vertical, ratio: 0.6,
            first: tree(arranging: surfaces[..<cut], random: &random, paneID: paneID + "1"),
            second: tree(arranging: surfaces[cut...], random: &random, paneID: paneID + "2"))
    }
}

/// The per-panel insertion the indexed graft replaced, kept as its oracle.
extension DeviceWorkspaceLayoutNode {
    fileprivate var referenceOrderedSurfaceIDs: [String] {
        switch self {
        case .pane(_, let surfaces, _): return surfaces
        case .split(_, _, let first, let second): return first.referenceOrderedSurfaceIDs + second.referenceOrderedSurfaceIDs
        }
    }

    fileprivate func referenceGrafting(_ kept: Set<String>, from local: DeviceWorkspaceLayoutNode) -> DeviceWorkspaceLayoutNode {
        var result = self
        local.referenceGraft(kept, into: &result)
        let present = Set(result.referenceOrderedSurfaceIDs)
        let known = local.referenceOrderedSurfaceIDs.filter { kept.contains($0) && !present.contains($0) }
        let stranded = known + kept.subtracting(present).subtracting(known).sorted()
        if let anchor = result.referenceOrderedSurfaceIDs.last {
            for surface in stranded.reversed() {
                result = result.referenceInserting(surface, beside: anchor, after: true)
            }
        }
        return result
    }

    private func referenceGraft(_ kept: Set<String>, into result: inout DeviceWorkspaceLayoutNode) {
        switch self {
        case .pane(_, let surfaces, _):
            var present = Set(result.referenceOrderedSurfaceIDs)
            for (index, surface) in surfaces.enumerated() where kept.contains(surface) && !present.contains(surface) {
                if let anchor = surfaces[..<index].last(where: { present.contains($0) }) {
                    result = result.referenceInserting(surface, beside: anchor, after: true)
                } else if let anchor = surfaces[(index + 1)...].first(where: { present.contains($0) }) {
                    result = result.referenceInserting(surface, beside: anchor, after: false)
                } else {
                    continue
                }
                present.insert(surface)
            }
        case .split(let direction, let ratio, let first, let second):
            let firstIsKept = !first.referenceOrderedSurfaceIDs.isEmpty && first.referenceOrderedSurfaceIDs.allSatisfy(kept.contains)
            let secondIsKept = !second.referenceOrderedSurfaceIDs.isEmpty && second.referenceOrderedSurfaceIDs.allSatisfy(kept.contains)
            guard firstIsKept != secondIsKept else {
                first.referenceGraft(kept, into: &result)
                second.referenceGraft(kept, into: &result)
                return
            }
            let (branch, sibling) = firstIsKept ? (first, second) : (second, first)
            let present = Set(result.referenceOrderedSurfaceIDs)
            let anchors = Set(sibling.referenceOrderedSurfaceIDs.filter { present.contains($0) })
            if !anchors.isEmpty {
                result = result.referenceWrapping(anchors, with: branch, direction: direction, ratio: ratio, branchFirst: firstIsKept)
            }
            sibling.referenceGraft(kept, into: &result)
        }
    }

    private func referenceInserting(_ surface: String, beside anchor: String, after: Bool) -> DeviceWorkspaceLayoutNode {
        switch self {
        case .pane(let id, var surfaces, let selected):
            guard let index = surfaces.firstIndex(of: anchor) else { return self }
            surfaces.insert(surface, at: after ? index + 1 : index)
            return .pane(id: id, surfaceIDs: surfaces, selectedSurfaceID: selected)
        case .split(let direction, let ratio, let first, let second):
            return .split(direction: direction, ratio: ratio,
                first: first.referenceInserting(surface, beside: anchor, after: after),
                second: second.referenceInserting(surface, beside: anchor, after: after))
        }
    }

    private func referenceWrapping(_ anchors: Set<String>, with branch: DeviceWorkspaceLayoutNode,
                                   direction: Direction, ratio: Double, branchFirst: Bool) -> DeviceWorkspaceLayoutNode {
        if case .split(let ownDirection, let ownRatio, let first, let second) = self {
            if anchors.isSubset(of: first.referenceOrderedSurfaceIDs) {
                return .split(direction: ownDirection, ratio: ownRatio,
                    first: first.referenceWrapping(anchors, with: branch, direction: direction, ratio: ratio, branchFirst: branchFirst),
                    second: second)
            }
            if anchors.isSubset(of: second.referenceOrderedSurfaceIDs) {
                return .split(direction: ownDirection, ratio: ownRatio, first: first,
                    second: second.referenceWrapping(anchors, with: branch, direction: direction, ratio: ratio, branchFirst: branchFirst))
            }
        }
        return branchFirst
            ? .split(direction: direction, ratio: ratio, first: branch, second: self)
            : .split(direction: direction, ratio: ratio, first: self, second: branch)
    }
}
