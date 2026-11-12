import CmuxConversationGeometry
import CoreGraphics
import Testing

@Suite struct ConversationPopEffectTests {
    @Test func debrisTilesTheWholeBubbleAndFliesOutward() {
        let size = CGSize(width: 200, height: 36)
        let pieces = ConversationPopEffect.pieces(for: size, seed: 7)
        #expect(pieces.count == 34 * 6)
        let area = pieces.reduce(0) { $0 + $1.source.width * $1.source.height }
        #expect(abs(area - size.width * size.height) < 0.001)
        #expect(pieces.allSatisfy { CGRect(origin: .zero, size: size).contains($0.source) })
        // Radial: pieces left of center go left, right of center go right.
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outward = pieces.filter { abs($0.source.midX - center.x) > 20 }
        #expect(outward.allSatisfy { ($0.source.midX - center.x) * $0.displacement.dx > 0 })
        // Outer pieces reach the clip margin, inner ones stay closer.
        let travel = pieces.map { hypot($0.displacement.dx, $0.displacement.dy) }
        #expect(travel.max()! > ConversationPopEffect.clipOutset)
        #expect(pieces.allSatisfy { $0.fadeEnd <= 1 && $0.fadeEnd > ConversationPopEffect.swellFraction })
    }

    @Test func planIsDeterministicPerSeedAndBoundedForLargeBubbles() {
        let size = CGSize(width: 300, height: 400)
        #expect(ConversationPopEffect.pieces(for: size, seed: 1) == ConversationPopEffect.pieces(for: size, seed: 1))
        #expect(ConversationPopEffect.pieces(for: size, seed: 1) != ConversationPopEffect.pieces(for: size, seed: 2))
        #expect(ConversationPopEffect.pieces(for: size, seed: 1).count <= 420)
        #expect(ConversationPopEffect.pieces(for: .zero, seed: 1).isEmpty)
    }
}
