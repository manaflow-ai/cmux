import CmuxFuzzSupport
import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

/// Stale and out-of-range layout state must refuse or clamp, never trap
/// (crash class index_subscript / int_conversion). Seeded property tests on
/// CmuxFuzzSupport, so a failure replays (long mode: CMUX_FUZZ_SECONDS).
@MainActor
@Suite struct RenderIndexFuzzTests {
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

    /// One input of either property, its choices read from `data` (the libFuzzer entry):
    /// a fresh model or controller, then steps until the input is used up.
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        if rng.bool() {
            let model = TranscriptModel()
            var t = 0.0
            for _ in 0..<64 where !rng.isExhausted { try rowSetStep(model, &t, &rng) }
        } else {
            let c = Fixtures.controller(width: 628, height: 900)
            for round in 0..<16 where !rng.isExhausted { viewportStep(c, round: round, &rng) }
        }
    }

    /// Sets a random row set or drops ghosts, then checks every position is finite and in range.
    static func rowSetStep(_ model: TranscriptModel, _ t: inout Double, _ rng: inout FuzzRNG) throws {
        t += rng.double(in: 0...2)
        if rng.bool() {
            let count = rng.int(in: 0...12)
            let specs = (0..<count).map { _ in
                RowSpec(key: "k\(rng.int(in: 0...20))", kind: .receipt("r"),
                        gap: CGFloat(rng.double(in: 0...8)), height: CGFloat(rng.double(in: 0...40)))
            }
            var seen = Set<String>()
            let unique = specs.filter { seen.insert($0.key).inserted }
            let before = model.snapshot
            model.set(unique, at: t, ghosts: rng.bool())
            for spec in unique { _ = before.contentTop(spec.key) }
        } else {
            model.dropGhosts(before: t - rng.double(in: 0...3))
        }
        try FuzzRun.check(model.offsets.count == model.count + 1, "\(model.offsets.count) offsets for \(model.count) rows")
        for i in -2..<(model.count + 2) {
            try FuzzRun.check(model.contentTop(i).isFinite, "row \(i) has no finite top")
        }
        let lo = odd[rng.below(odd.count)], hi = odd[rng.below(odd.count)]
        for (a, b) in [(lo, hi), (CGFloat(-50), model.total + 50)] {
            let r = model.range(a, b)
            try FuzzRun.check(r.lowerBound >= 0 && r.upperBound <= model.count, "range(\(a), \(b)) = \(r) past \(model.count) rows")
        }
    }

    @Test func randomRowSetsKeepPositionsConsistent() throws {
        let model = TranscriptModel()
        var t = 0.0
        try FuzzRun("RenderIndex.rowSets", seed: 0xC0FFEE, iterations: 400).forEach { rng in
            try Self.rowSetStep(model, &t, &rng)
        }
    }

    @Test func malformedAccessibilityIdsGiveNoReactionTarget() {
        let c = Fixtures.controller(width: 628, height: 900)
        let messages = Fixtures.conversation(4)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let key = IdempotencyKey("key_1")
        for id in ["part:", "part:3", "part:key_1:-1", "part:key_1:99", "part:key_1:x", "receipt:key_1"] {
            let element = HomeAXItem(id: id, role: .staticText, label: "", value: "", frame: .zero, item: key)
            #expect(c.reactionTarget(for: element, isOnline: true) == nil, "\(id)")
        }
    }

    static let viewportSizes: [CGSize] = [CGSize(width: 1, height: 1), CGSize(width: 0, height: 0), CGSize(width: 320, height: 200),
                                          CGSize(width: 4000, height: 3000), CGSize(width: 628, height: 900)]

    /// Updates, resizes, scrolls and hit-tests the controller once.
    static func viewportStep(_ c: HomeController, round: Int, _ rng: inout FuzzRNG) {
        let count = rng.int(in: 0...30)
        let messages = Fixtures.conversation(count, firstSeq: Seq(rng.int(in: 1...5)))
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: round % 3 == 0 ? [Fixtures.chief] : [],
                 hasOlder: rng.bool())
        if round % 4 == 0 { c.resize(to: viewportSizes[rng.below(viewportSizes.count)]) }
        c.hostScrolled(to: CGFloat(rng.double(in: -2000...2000)))
        for _ in 0..<8 {
            let p = CGPoint(x: CGFloat(rng.double(in: -10...700)), y: CGFloat(rng.double(in: -10...1000)))
            _ = c.hit(at: p)
        }
        _ = c.hits(in: CGRect(x: -5, y: -5, width: 900, height: 1200))
        _ = c.accessibilityItems()
        let target = IdempotencyKey("key_\(rng.int(in: 0...40))")
        _ = c.contentFrame(for: target)
        _ = c.scroll(to: target, anchor: rng.bool() ? .top : .center)
        _ = c.videoState(for: target, partIndex: rng.int(in: -2...3))
    }

    @Test func randomViewportsHitsAndScrollsDoNotTrap() throws {
        let c = Fixtures.controller(width: 628, height: 900)
        var round = 0
        try FuzzRun("RenderIndex.viewports", seed: 0x5EED, iterations: 60).forEach { rng in
            Self.viewportStep(c, round: round, &rng)
            round += 1
        }
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("RenderIndex.oneInput", seed: 0x5EEE, iterations: 32)
        // Choice tapes, one per branch: even bytes go to the viewport steps, odd ones to the row sets.
        try run.forEachInput(run.corpus(seeds: [Data([0]), Data([1])])) { try Self.oneInput($0) }
    }
}
