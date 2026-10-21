import CoreGraphics
import Testing
@testable import CmuxConversationGeometry

@Suite struct ConversationTranscriptPixelGridTests {
    typealias Grid = ConversationTranscriptPixelGrid

    /// Raw tops for rows of `heights` with `gap` between them, from `start`.
    func rawTops(_ heights: [CGFloat], gap: CGFloat, start: CGFloat) -> [CGFloat] {
        var y = start
        return heights.enumerated().map { index, height in
            if index > 0 { y += gap }
            defer { y += height }
            return y
        }
    }

    @Test func rowsLandOnChatKitsPixelsAsTheyStack() {
        let tops = rawTops([40.287, 40.287, 40.287], gap: 4, start: 232.33).map { Grid.snap($0, phase: 0, scale: 3) }
        #expect(abs(tops[0] - 232.333) < 0.001)
        #expect(abs(tops[1] - 276.667) < 0.001)
        #expect(abs(tops[2] - 321.000) < 0.001)
    }

    /// An older page lands above: every row that was there moves by the
    /// same whole number of pixels, so none steps against its neighbors.
    @Test func aPageLandingAboveMovesEveryRowBelowByTheSamePixels() {
        let scale: CGFloat = 3
        let heights: [CGFloat] = [40.287, 61.9, 20.45, 40.287, 133.71, 40.287, 82.06]
        let old = rawTops(heights, gap: 2.5, start: 10)
        let oldTops = old.map { Grid.snap($0, phase: 0, scale: scale) }
        for page in [CGFloat(523.41), 1001.13, 17.2, 0.1, 812.66] {
            let new = old.map { $0 + page }
            let anchor = 3
            let phase = Grid.phase(placing: new[anchor], likePreviousTop: old[anchor], scale: scale)
            #expect(abs(phase) <= 0.5 / scale + 0.0001)
            let moves = zip(new, oldTops).map { Grid.snap($0.0, phase: phase, scale: scale) - $0.1 }
            for move in moves {
                #expect(abs(move - moves[0]) < 0.0001, "page \(page): moves \(moves)")
                #expect(abs((move * scale).rounded() - move * scale) < 0.0001)
            }
        }
    }

    /// Nothing above changed: the phase carries over.
    @Test func anUnchangedRowKeepsThePhase() {
        let phase = Grid.phase(placing: 412.25, likePreviousTop: 412.25 + 0.1, scale: 3)
        #expect(abs(phase - 0.1) < 0.0001)
    }
}
