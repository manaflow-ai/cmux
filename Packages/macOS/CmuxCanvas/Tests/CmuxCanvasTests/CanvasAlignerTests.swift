import Testing
@testable import CmuxCanvas

import Foundation

struct CanvasAlignerTests {
    private let metrics = CanvasMetrics(gap: 16, snapThreshold: 8)
    private var aligner: CanvasAligner { CanvasAligner(metrics: metrics) }

    private func id(_ value: UInt8) -> CanvasPaneID {
        CanvasPaneID(rawValue: UUID(uuid: (
            value, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )))
    }

    private func layout(_ frames: [(UInt8, CanvasRect)]) -> CanvasLayout {
        var layout = CanvasLayout()
        for (value, frame) in frames {
            layout.add(CanvasPane(id: id(value), frame: frame))
        }
        return layout
    }

    @Test func alignLeftUsesLeftmostEdge() {
        let layout = layout([
            (1, CanvasRect(x: 50, y: 0, width: 100, height: 100)),
            (2, CanvasRect(x: 20, y: 200, width: 100, height: 100)),
            (3, CanvasRect(x: 80, y: 400, width: 100, height: 100)),
        ])
        let frames = aligner.frames(applying: .alignLeft, to: layout.paneIDs, in: layout)
        #expect(frames[id(1)]?.x == 20)
        #expect(frames[id(3)]?.x == 20)
        // The already-aligned pane is not reported as changed.
        #expect(frames[id(2)] == nil)
    }

    @Test func alignRightUsesRightmostEdge() {
        let layout = layout([
            (1, CanvasRect(x: 0, y: 0, width: 100, height: 100)),
            (2, CanvasRect(x: 0, y: 200, width: 300, height: 100)),
        ])
        let frames = aligner.frames(applying: .alignRight, to: layout.paneIDs, in: layout)
        #expect(frames[id(1)] == CanvasRect(x: 200, y: 0, width: 100, height: 100))
        #expect(frames[id(2)] == nil)
    }

    @Test func alignTopAndBottom() {
        let layout = layout([
            (1, CanvasRect(x: 0, y: 30, width: 100, height: 100)),
            (2, CanvasRect(x: 200, y: 10, width: 100, height: 150)),
        ])
        let tops = aligner.frames(applying: .alignTop, to: layout.paneIDs, in: layout)
        #expect(tops[id(1)]?.y == 10)
        let bottoms = aligner.frames(applying: .alignBottom, to: layout.paneIDs, in: layout)
        #expect(bottoms[id(1)]?.maxY == 160)
        #expect(bottoms[id(2)] == nil)
    }

    @Test func equalizeWidthsCopiesReferencePane() {
        let layout = layout([
            (1, CanvasRect(x: 0, y: 0, width: 250, height: 100)),
            (2, CanvasRect(x: 300, y: 0, width: 400, height: 100)),
        ])
        let frames = aligner.frames(
            applying: .equalizeWidths,
            to: layout.paneIDs,
            in: layout,
            reference: id(1)
        )
        #expect(frames[id(2)] == CanvasRect(x: 300, y: 0, width: 250, height: 100))
        #expect(frames[id(1)] == nil)
    }

    @Test func equalizeHeightsFallsBackToTallest() {
        let layout = layout([
            (1, CanvasRect(x: 0, y: 0, width: 100, height: 120)),
            (2, CanvasRect(x: 200, y: 0, width: 100, height: 300)),
        ])
        let frames = aligner.frames(applying: .equalizeHeights, to: layout.paneIDs, in: layout)
        #expect(frames[id(1)]?.height == 300)
        #expect(frames[id(2)] == nil)
    }

    @Test func distributeHorizontallyPacksAtGap() {
        let layout = layout([
            (1, CanvasRect(x: 0, y: 0, width: 100, height: 100)),
            (2, CanvasRect(x: 500, y: 50, width: 100, height: 100)),
            (3, CanvasRect(x: 130, y: 25, width: 50, height: 100)),
        ])
        let frames = aligner.frames(applying: .distributeHorizontally, to: layout.paneIDs, in: layout)
        // Order by current x: 1 (stays), 3, 2. Vertical positions unchanged.
        #expect(frames[id(1)] == nil)
        #expect(frames[id(3)] == CanvasRect(x: 116, y: 25, width: 50, height: 100))
        #expect(frames[id(2)] == CanvasRect(x: 182, y: 50, width: 100, height: 100))
    }

    @Test func distributeVerticallyPacksAtGap() {
        let layout = layout([
            (1, CanvasRect(x: 0, y: 0, width: 100, height: 100)),
            (2, CanvasRect(x: 50, y: 400, width: 100, height: 80)),
        ])
        let frames = aligner.frames(applying: .distributeVertically, to: layout.paneIDs, in: layout)
        #expect(frames[id(2)] == CanvasRect(x: 50, y: 116, width: 100, height: 80))
    }

    @Test func tidyPacksMessyPanesIntoRows() {
        // Two visual rows with jitter: panes 1,2 around y≈0; pane 3 clearly below.
        let layout = layout([
            (1, CanvasRect(x: 7, y: 5, width: 200, height: 150)),
            (2, CanvasRect(x: 260, y: -12, width: 200, height: 150)),
            (3, CanvasRect(x: 30, y: 320, width: 200, height: 150)),
        ])
        let frames = aligner.frames(applying: .tidy, to: layout.paneIDs, in: layout)
        // Origin is (minX, minY) of the selection = (7, -12). Within the first
        // row, pane 1 (midX 107) precedes pane 2 (midX 360).
        #expect(frames[id(1)] == CanvasRect(x: 7, y: -12, width: 200, height: 150))
        #expect(frames[id(2)] == CanvasRect(x: 223, y: -12, width: 200, height: 150))
        #expect(frames[id(3)] == CanvasRect(x: 7, y: 154, width: 200, height: 150))
    }

    @Test func tidyPreservesSizes() {
        let layout = layout([
            (1, CanvasRect(x: 0, y: 0, width: 320, height: 180)),
            (2, CanvasRect(x: 900, y: 12, width: 200, height: 260)),
        ])
        let frames = aligner.frames(applying: .tidy, to: layout.paneIDs, in: layout)
        let sizes = layout.panes.map { frames[$0.id]?.size ?? $0.frame.size }
        #expect(sizes == [CanvasSize(width: 320, height: 180), CanvasSize(width: 200, height: 260)])
    }

    @Test func fewerThanTwoPanesIsANoOp() {
        let layout = layout([(1, CanvasRect(x: 0, y: 0, width: 100, height: 100))])
        for command in CanvasAlignmentCommand.allCases {
            #expect(aligner.frames(applying: command, to: layout.paneIDs, in: layout).isEmpty)
        }
    }

    @Test func unknownIDsAreIgnored() {
        let layout = layout([
            (1, CanvasRect(x: 50, y: 0, width: 100, height: 100)),
            (2, CanvasRect(x: 20, y: 200, width: 100, height: 100)),
        ])
        let frames = aligner.frames(
            applying: .alignLeft,
            to: layout.paneIDs + [id(99)],
            in: layout
        )
        #expect(frames.count == 1)
        #expect(frames[id(1)]?.x == 20)
    }
}
