import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

/// Stale and out-of-range layout state must refuse or clamp, never trap
/// (crash class index_subscript / int_conversion). Seeded, so a failure
/// replays.
@MainActor
@Suite struct RenderIndexFuzzTests {
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let odd: [CGFloat] = [.nan, .infinity, -.infinity, -1, 0, 0.4, 1e300, -1e300, .greatestFiniteMagnitude]

    @Test func aBitmapOfANonFiniteOrHugeSizeDoesNotTrap() {
        for w in Self.odd {
            for h in Self.odd {
                _ = Canvas.image(size: CGSize(width: w, height: h)) { _ in }
            }
        }
        let normal = Canvas.image(size: CGSize(width: 3, height: 2)) { _ in }
        #expect(normal?.width == 6)
        #expect(normal?.height == 4)
    }

    @Test func aStaleRowIndexGivesNoPositionInsteadOfTrapping() {
        let model = TranscriptModel()
        #expect(model.contentTop(5) == 0)
        #expect(model.contentTop(-1) == 0)
        let stale = TranscriptModel.Snapshot(index: ["gone": 3], offsets: [0], rows: [])
        #expect(stale.contentTop("gone") == nil)
    }

    @Test func decoratingARowOfAStaleIndexDoesNothing() {
        let c = Fixtures.controller(width: 628, height: 900)
        c.update(items: Fixtures.items(Fixtures.conversation(6)), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let row = RowLayer()
        c.scene.decorate(row, c.scene.model.count + 7)
        c.scene.decorate(row, -1)
        #expect(row.key.isEmpty, "a stale index configures nothing")
    }

    @Test func randomRowSetsKeepPositionsConsistent() {
        var rng = SplitMix(state: 0xC0FFEE)
        let model = TranscriptModel()
        var t = 0.0
        for _ in 0..<400 {
            t += Double.random(in: 0...2, using: &rng)
            if Bool.random(using: &rng) {
                let count = Int.random(in: 0...12, using: &rng)
                let specs = (0..<count).map { _ in
                    RowSpec(key: "k\(Int.random(in: 0...20, using: &rng))", kind: .receipt("r"),
                            gap: CGFloat.random(in: 0...8, using: &rng), height: CGFloat.random(in: 0...40, using: &rng))
                }
                var seen = Set<String>()
                let unique = specs.filter { seen.insert($0.key).inserted }
                let before = model.snapshot
                model.set(unique, at: t, ghosts: Bool.random(using: &rng))
                for spec in unique { _ = before.contentTop(spec.key) }
            } else {
                model.dropGhosts(before: t - Double.random(in: 0...3, using: &rng))
            }
            #expect(model.offsets.count == model.count + 1)
            for i in -2..<(model.count + 2) {
                let top = model.contentTop(i)
                #expect(top.isFinite)
            }
            let lo = Self.odd.randomElement(using: &rng) ?? 0, hi = Self.odd.randomElement(using: &rng) ?? 0
            for (a, b) in [(lo, hi), (CGFloat(-50), model.total + 50)] {
                let r = model.range(a, b)
                #expect(r.lowerBound >= 0 && r.upperBound <= model.count)
            }
        }
    }

    @Test func malformedAccessibilityIdsGiveNoReactionTarget() {
        let c = Fixtures.controller(width: 628, height: 900)
        let messages = Fixtures.conversation(4)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let key = IdempotencyKey("key_1")
        for id in ["part:", "part:3", "part:key_1:-1", "part:key_1:99", "part:key_1:x", "part::0", "receipt:key_1"] {
            let element = HomeAXItem(id: id, role: .staticText, label: "", value: "", frame: .zero, item: key)
            #expect(c.reactionTarget(for: element, isOnline: true) == nil, "\(id)")
        }
    }

    @Test func randomViewportsHitsAndScrollsDoNotTrap() {
        var rng = SplitMix(state: 0x5EED)
        let c = Fixtures.controller(width: 628, height: 900)
        let sizes: [CGSize] = [CGSize(width: 1, height: 1), CGSize(width: 0, height: 0), CGSize(width: 320, height: 200),
                               CGSize(width: 4000, height: 3000), CGSize(width: 628, height: 900)]
        for round in 0..<60 {
            let count = Int.random(in: 0...30, using: &rng)
            let messages = Fixtures.conversation(count, firstSeq: Seq(Int.random(in: 1...5, using: &rng)))
            c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: round % 3 == 0 ? [Fixtures.chief] : [],
                     hasOlder: Bool.random(using: &rng))
            if round % 4 == 0, let size = sizes.randomElement(using: &rng) { c.resize(to: size) }
            c.hostScrolled(to: CGFloat.random(in: -2000...2000, using: &rng))
            for _ in 0..<8 {
                let p = CGPoint(x: CGFloat.random(in: -10...700, using: &rng), y: CGFloat.random(in: -10...1000, using: &rng))
                _ = c.hit(at: p)
            }
            _ = c.hits(in: CGRect(x: -5, y: -5, width: 900, height: 1200))
            _ = c.accessibilityItems()
            let target = IdempotencyKey("key_\(Int.random(in: 0...40, using: &rng))")
            _ = c.contentFrame(for: target)
            _ = c.scroll(to: target, anchor: Bool.random(using: &rng) ? .top : .center)
            _ = c.videoState(for: target, partIndex: Int.random(in: -2...3, using: &rng))
        }
    }
}
