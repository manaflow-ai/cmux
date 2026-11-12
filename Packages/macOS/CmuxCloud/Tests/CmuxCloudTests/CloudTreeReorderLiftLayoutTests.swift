import CmuxCloud
import CoreGraphics
import Testing

@Suite("Cloud tree reorder lift layout")
struct CloudTreeReorderLiftLayoutTests {
    /// Rows stacked top-down from y = 0 with the given heights.
    private func frames(_ heights: [CGFloat]) -> [CGRect] {
        var y: CGFloat = 0
        return heights.map { height in
            defer { y += height }
            return CGRect(x: 0, y: y, width: 200, height: height)
        }
    }

    /// Four one-row machines, 30pt each.
    private func fourMachines(source: Int) throws -> CloudTreeReorderLiftLayout {
        try #require(CloudTreeReorderLiftLayout(
            frames: frames([30, 30, 30, 30]),
            blocks: (0..<4).map { .init(rows: $0..<($0 + 1), isPeer: true) },
            sourceIndex: source
        ))
    }

    @Test("At rest nothing moves and the source keeps its slot")
    func rest() throws {
        let placement = try fourMachines(source: 1).placement(dragOffset: 0)
        #expect(placement.slot == 1)
        #expect(placement.sourceOffset == 0)
        #expect(placement.sourceSlotOffset == 0)
        #expect(placement.rowOffsets.values.allSatisfy { $0 == 0 })
    }

    @Test("A neighbour gives way once half of it is covered, not before")
    func neighbourThreshold() throws {
        let layout = try fourMachines(source: 0)
        let short = layout.placement(dragOffset: 15)
        #expect(short.slot == 0)
        #expect(short.rowOffsets[1] == 0)
        let past = layout.placement(dragOffset: 16)
        #expect(past.slot == 1)
        #expect(past.rowOffsets[1] == -30)
        #expect(past.rowOffsets[2] == 0)
        #expect(past.sourceOffset == 16, "the block stays under the pointer")
        #expect(past.sourceSlotOffset == 30)
    }

    @Test("Dragging up moves the rows above down")
    func dragUp() throws {
        let placement = try fourMachines(source: 3).placement(dragOffset: -76)
        #expect(placement.slot == 0)
        #expect(placement.rowOffsets[0] == 30)
        #expect(placement.rowOffsets[1] == 30)
        #expect(placement.rowOffsets[2] == 30)
        #expect(placement.sourceSlotOffset == -90)
    }

    @Test("The block resists past the span's ends and the slot stays at the end")
    func overscroll() throws {
        let layout = try fourMachines(source: 1)
        let pulled = layout.placement(dragOffset: -500)
        #expect(pulled.slot == 0)
        #expect(pulled.sourceOffset < -30)
        #expect(pulled.sourceOffset > -30 - CloudTreeReorderLiftLayout.overscrollLimit)
        let down = layout.placement(dragOffset: 500)
        #expect(down.slot == 3)
        #expect(down.sourceOffset > 60)
        #expect(down.sourceOffset < 60 + CloudTreeReorderLiftLayout.overscrollLimit)
    }

    @Test("An open machine moves as one block and peers clear its full height")
    func openMachineBlock() throws {
        // Machine 0 is open with three rows under it; machines 1 and 2 are closed.
        let layout = try #require(CloudTreeReorderLiftLayout(
            frames: frames([30, 24, 24, 24, 30, 30]),
            blocks: [.init(rows: 0..<4, isPeer: true), .init(rows: 4..<5, isPeer: true), .init(rows: 5..<6, isPeer: true)],
            sourceIndex: 0
        ))
        // The open block is 102pt; the one-line neighbour moves once its half is covered.
        let placement = layout.placement(dragOffset: 16)
        #expect(placement.slot == 1)
        #expect(placement.rowOffsets[4] == -102)
        #expect(placement.rowOffsets[5] == 0)
        #expect(placement.sourceSlotOffset == 30)
        #expect(placement.rowOffsets[1] == nil, "the source's own rows travel with the block")
    }

    @Test("A one-line machine passes an open one after covering half of itself")
    func passingOpenMachine() throws {
        // Machine 1 is open (30 + 3 x 24); the source is the closed machine 0.
        let layout = try #require(CloudTreeReorderLiftLayout(
            frames: frames([30, 30, 24, 24, 24]),
            blocks: [.init(rows: 0..<1, isPeer: true), .init(rows: 1..<5, isPeer: true)],
            sourceIndex: 0
        ))
        #expect(layout.placement(dragOffset: 15).slot == 0)
        let placement = layout.placement(dragOffset: 16)
        #expect(placement.slot == 1)
        for row in 1..<5 { #expect(placement.rowOffsets[row] == -30) }
        #expect(placement.sourceSlotOffset == 102)
    }

    @Test("Blocks outside the source's tier and fixed rows inside it hold still")
    func fixedBlocks() throws {
        // 0 pinned (other tier), 1 source, 2 a pending create (fixed), 3 peer.
        let layout = try #require(CloudTreeReorderLiftLayout(
            frames: frames([30, 30, 30, 30]),
            blocks: [
                .init(rows: 0..<1, isPeer: false), .init(rows: 1..<2, isPeer: true),
                .init(rows: 2..<3, isPeer: false), .init(rows: 3..<4, isPeer: true)
            ],
            sourceIndex: 1
        ))
        #expect(layout.peerCount == 1)
        let up = layout.placement(dragOffset: -200)
        #expect(up.slot == 0, "the other tier is outside the span")
        #expect(up.sourceOffset > -CloudTreeReorderLiftLayout.overscrollLimit)
        let down = layout.placement(dragOffset: 200)
        #expect(down.slot == 1)
        #expect(down.rowOffsets[2] == 0, "the fixed row keeps its slot")
        #expect(down.rowOffsets[3] == -60)
        #expect(down.rowOffsets[0] == nil)
        #expect(down.sourceSlotOffset == 60)
    }

    @Test("Bad input is rejected")
    func invalid() {
        #expect(CloudTreeReorderLiftLayout(frames: frames([30]), blocks: [.init(rows: 0..<2, isPeer: true)], sourceIndex: 0) == nil)
        #expect(CloudTreeReorderLiftLayout(frames: frames([30]), blocks: [.init(rows: 0..<1, isPeer: true)], sourceIndex: 1) == nil)
    }
}
