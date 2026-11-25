@testable import CmuxNextApps
import Foundation
import Testing

/// `Particles {choreography}` (ABI.md "Particles choreography"): the native player plays a document of
/// our own frame by frame, with the web player's numbers (`webviews/src/apps/scene/choreography.test.ts`,
/// the same fixture and expected values). The fixture is a three-dot glyph shaped like a working
/// indicator (a big middle dot between two small ones; the ends grow and spread while the middle
/// shrinks; then back), plus a hand-off dot, a one-frame hide, a count-up intro and a generated
/// two-site orbit.
struct AppSceneChoreographyTests {
    typealias Dot = AppSceneChoreography.Dot
    typealias Player = AppSceneChoreography.Player
    typealias Request = AppSceneChoreography.Request

    private static func dots(_ list: [[Double]]) -> AppJSON {
        .array(list.map { triple in .array(triple.map { AppJSON.number($0) }) })
    }

    private static func frame(_ at: Double, _ list: [[Double]], ease: String? = nil) -> AppJSON {
        var fields: [String: AppJSON] = ["at": .number(at), "dots": dots(list)]
        if let ease { fields["ease"] = .string(ease) }
        return .object(fields)
    }

    private static let tradeRest: [[Double]] = [[-6, 0, 0.6], [0, 0, 1.2], [6, 0, 0.6]]
    private static let tradeOut: [[Double]] = [[-8, 0, 1], [0, 0, 0.5], [8, 0, 1]]

    static func fixture() -> [String: AppJSON] {
        let lone: AppJSON = .object([
            "duration": 400, "ease": "easeInOut",
            "frames": .array([frame(0, [[0, 0, 0.5]]), frame(1, [[0, 0, 0.5]])]),
        ])
        let none: AppJSON = .object(["duration": 200, "frames": .array([frame(0, [])])])
        let trade: AppJSON = .object([
            "duration": 1000, "ease": "easeInOut",
            "frames": .array([
                frame(0, tradeRest),
                frame(0.25, tradeRest),
                frame(0.5, tradeOut),
                frame(0.75, [[-6, 0, 0.8], [0, 0, 0.8], [6, 0, 0.8]], ease: "linear"),
                frame(1, tradeRest),
            ]),
        ])
        let count: AppJSON = .object([
            "duration": 400, "ease": "linear",
            "frames": .array([
                frame(0, [[0, 0, 0.5]]),
                frame(0.5, [[-3, 0, 1], [3, 0, 1]]),
                .object(["at": 1, "formation": "row"]),
            ]),
        ])
        let lifeFrames: [AppJSON] = [
            .object(["at": 0, "pos": "centre", "s": 0.2]),
            .object(["at": 0.5, "pos": "site", "s": 1]),
            .object(["at": 1, "pos": "between", "s": 0]),
        ]
        let orbit: AppJSON = .object([
            "duration": 800,
            "sites": .array([.array([-6, 0]), .array([6, 0])]),
            "spawn": .object(["every": 400, "order": .array([0, 1]), "life": 800]),
            "lifeFrames": .array(lifeFrames),
        ])
        let triggers: AppJSON = .object([
            "read": .array(["orbit"]),
            "execute": .array(["trade"]),
            "sendMessage": .object(["intro": .array(["count"]), "loop": .array(["trade"])]),
            "idle": .array(["none"]),
            "cycle": .array(["trade", "lone", "orbit", "lone"]),
        ])
        return [
            "$schema": "cmux.particles/1",
            "particle": .object(["shape": "circle", "size": 4, "color": "accent", "max": 4]),
            "phases": .object(["lone": lone, "none": none, "trade": trade, "count": count, "orbit": orbit]),
            "triggers": triggers,
        ]
    }

    private static func doc() throws -> AppSceneChoreography {
        try #require(AppSceneChoreography(json: .object(fixture())), "fixture did not parse")
    }

    private static func phase(_ doc: AppSceneChoreography, _ name: String) throws -> AppSceneChoreography.Phase {
        try #require(doc.phases[name])
    }

    /// bun's `toBeCloseTo(x, digits)`: |actual - expected| < 10^-digits / 2.
    private static func near(_ actual: Double, _ expected: Double, digits: Int = 3) -> Bool {
        abs(actual - expected) < pow(10, -Double(digits)) / 2
    }

    private static func close(_ actual: [Dot], _ expected: [[Double]], digits: Int = 3,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        for (index, triple) in expected.enumerated() where index < actual.count {
            let dot = actual[index]
            #expect(near(dot.x, triple[0], digits: digits), "dot \(index) x \(dot.x) != \(triple[0])", sourceLocation: sourceLocation)
            #expect(near(dot.y, triple[1], digits: digits), "dot \(index) y \(dot.y) != \(triple[1])", sourceLocation: sourceLocation)
            #expect(near(dot.s, triple[2], digits: digits), "dot \(index) s \(dot.s) != \(triple[2])", sourceLocation: sourceLocation)
        }
    }

    private static func inOut(_ u: Double) -> Double {
        AppSceneChoreography.easeProgress(.bezier(0.42, 0, 0.58, 1), u, segmentMs: 0)
    }

    // MARK: Easing

    @Test func curvesPassThroughTheirEndsAndTheStandardEaseInOutIsSymmetric() {
        #expect(Self.near(AppSceneChoreography.easeProgress(.linear, 0.3, segmentMs: 100), 0.3, digits: 6))
        #expect(Self.inOut(0) == 0)
        #expect(Self.inOut(1) == 1)
        #expect(Self.near(Self.inOut(0.5), 0.5, digits: 4))
        #expect(Self.near(Self.inOut(0.25) + Self.inOut(0.75), 1, digits: 4))
        #expect(Self.inOut(0.25) < 0.25)
        // A spring follows time, not the share: a short segment ends before it settles and snaps at 1.
        let spring = AppSceneChoreography.Ease.spring(period: 0.3, damping: 1)
        #expect(AppSceneChoreography.easeProgress(spring, 0.5, segmentMs: 2000) > 0.99)
        #expect(AppSceneChoreography.easeProgress(spring, 0.5, segmentMs: 100) < 0.5)
        #expect(AppSceneChoreography.easeProgress(spring, 1, segmentMs: 100) == 1)
    }

    // MARK: One phase

    @Test func theTradingPhasePlacesEveryDotAtItsFrameTimesAndEasesBetween() throws {
        let d = try Self.doc()
        let trade = try Self.phase(d, "trade")
        // On the frames: exact.
        Self.close(d.samplePhase(trade, ms: 0, from: nil), Self.tradeRest)
        Self.close(d.samplePhase(trade, ms: 250, from: nil), Self.tradeRest)
        Self.close(d.samplePhase(trade, ms: 500, from: nil), Self.tradeOut)
        Self.close(d.samplePhase(trade, ms: 1000, from: nil), Self.tradeRest)
        // Held between 0 and 0.25 (equal frames), eased between 0.25 and 0.5 by the phase's ease-in-out.
        Self.close(d.samplePhase(trade, ms: 100, from: nil), Self.tradeRest)
        let p = Self.inOut(0.5) // halfway through the 0.25..0.5 segment
        Self.close(d.samplePhase(trade, ms: 375, from: nil), [
            [-6 - 2 * p, 0, 0.6 + 0.4 * p],
            [0, 0, 1.2 - 0.7 * p],
            [6 + 2 * p, 0, 0.6 + 0.4 * p],
        ])
        // A frame's own ease shapes the segment that ends at it: 0.5..0.75 is linear.
        Self.close(d.samplePhase(trade, ms: 625, from: nil), [[-7, 0, 0.9], [0, 0, 0.65], [7, 0, 0.9]])
    }

    @Test func aDotAFrameDoesNotListHidesAtTheCentreAndANamedFormationResolvesInParticleSizes() throws {
        let d = try Self.doc()
        let count = try Self.phase(d, "count")
        Self.close(d.samplePhase(count, ms: 0, from: nil), [[0, 0, 0.5]])
        // Halfway to the pair: dot 0 moves out, dot 1 grows out of the centre.
        Self.close(d.samplePhase(count, ms: 100, from: nil), [[-1.5, 0, 0.75], [1.5, 0, 0.5]])
        let row = try #require(AppSceneChoreography.builtInFormation("row", size: 4))
        Self.close(d.samplePhase(count, ms: 400, from: nil), row.map { [$0.x, $0.y, $0.s] })
        #expect(Self.near(row[2].x, 8.8, digits: 6))
    }

    @Test func aPhaseAfterAnotherEasesFromTheDotsOnScreenInsteadOfItsFirstFrame() throws {
        let d = try Self.doc()
        let lone = try Self.phase(d, "lone")
        let from = [Dot(x: -6, y: 0, s: 0.6), Dot(x: 0, y: 0, s: 1.2), Dot(x: 6, y: 0, s: 0.6)]
        Self.close(d.samplePhase(lone, ms: 0, from: from), Self.tradeRest)
        let p = Self.inOut(0.5)
        Self.close(d.samplePhase(lone, ms: 200, from: from), [
            [-6 * (1 - p), 0, 0.6 + (0.5 - 0.6) * p],
            [0, 0, 1.2 * (1 - p)],
            [6 * (1 - p), 0, 0.6 * (1 - p)],
        ])
        Self.close(d.samplePhase(lone, ms: 400, from: from), [[0, 0, 0.5], [0, 0, 0], [0, 0, 0]])
        // A phase whose frames all sit at 0 eases into them over its whole duration.
        let none = try Self.phase(d, "none")
        Self.close(d.samplePhase(none, ms: 100, from: from), [[-3, 0, 0.3], [0, 0, 0.6], [3, 0, 0.3]])
        Self.close(d.samplePhase(none, ms: 200, from: from), [[0, 0, 0], [0, 0, 0], [0, 0, 0]])
    }

    @Test func aGeneratedPhaseBirthsEachDotAtTheCentreFliesItToItsSiteAndGathersItBack() throws {
        let d = try Self.doc()
        let orbit = try Self.phase(d, "orbit")
        // First pass, nothing carried: one dot born at 0 heading to site 0.
        Self.close(d.samplePhase(orbit, ms: 0, from: nil), [[0, 0, 0.2]])
        Self.close(d.samplePhase(orbit, ms: 200, from: nil), [[-3, 0, 0.6]])
        // 400 ms: dot 0 at its site, dot 1 born for site 1.
        Self.close(d.samplePhase(orbit, ms: 400, from: nil), [[-6, 0, 1], [0, 0, 0.2]])
        // 600 ms: dot 0 halfway to the midpoint of site and centre, dot 1 halfway out.
        Self.close(d.samplePhase(orbit, ms: 600, from: nil), [[-4.5, 0, 0.5], [3, 0, 0.6]])
        // Repeating itself, the previous pass's dot is still alive at 0.
        Self.close(d.samplePhase(orbit, ms: 0, from: nil, carry: true), [[6, 0, 1], [0, 0, 0.2]])
    }

    // MARK: The player

    @Test func aTriggersPhaseLoopsAndAChangedTriggerHandsOffThroughLoneWhenThePhaseEnds() throws {
        let d = try Self.doc()
        var player = Player(d, request: Request(trigger: "execute"), now: 0)
        #expect(player.current.phase == "trade")
        _ = player.sample(999)
        player.setRequest(Request(trigger: "read"))
        // Read only at the hand-off: the trade still finishes.
        Self.close(player.sample(500), Self.tradeOut)
        _ = player.sample(1000)
        #expect(player.current.phase == "lone")
        #expect(player.current.start == 1000)
        Self.close(player.sample(1399.9), [[0, 0, 0.5], [0, 0, 0], [0, 0, 0]], digits: 2)
        _ = player.sample(1400)
        #expect(player.current.phase == "orbit")
        #expect(player.current.start == 1400)
        // The orbit starts with nothing alive; the lone dot gathers into the centre over the first spawn.
        let start = player.sample(1400)
        #expect(start.first == Dot(x: 0, y: 0, s: 0.2))
        #expect(!player.sample(2200 + 400).isEmpty)
        #expect(player.current.phase == "orbit")
    }

    @Test func anUnknownKindPlaysCycleInOrderAndTheCycleLoops() throws {
        let d = try Self.doc()
        var player = Player(d, request: Request(trigger: "switch_mode"), now: 0)
        var seen: [String] = []
        var t = 0.0
        while t < 2 * (1000 + 400 + 800 + 400) {
            _ = player.sample(t)
            if seen.last != player.current.phase { seen.append(player.current.phase) }
            t += 50
        }
        #expect(seen == ["trade", "lone", "orbit", "lone", "trade", "lone", "orbit", "lone"])
    }

    @Test func anIntroPlaysOnceThenTheLoopRepeatsAndAPhaseRequestLoopsThatPhase() throws {
        let d = try Self.doc()
        var player = Player(d, request: Request(trigger: "sendMessage"), now: 0)
        var seen: [String] = []
        var t = 0.0
        while t < 3500 {
            _ = player.sample(t)
            if seen.last != player.current.phase { seen.append(player.current.phase) }
            t += 50
        }
        #expect(seen == ["count", "trade"])
        #expect(player.current.start == 3400)
        var jump = Player(d, request: Request(phase: "trade", trigger: "read"), now: 0)
        _ = jump.sample(5000)
        #expect(jump.current.phase == "trade")
        #expect(jump.current.start == 5000)
        // Repeating itself it starts from where it ended (its last frame equals its first here).
        Self.close(jump.sample(5500), Self.tradeOut)
    }

    @Test func theStillIsTheFirstFrameOfWhatWouldPlay() throws {
        let d = try Self.doc()
        Self.close(Player(d, request: Request(trigger: "execute"), now: 0).still(), Self.tradeRest)
        Self.close(Player(d, request: Request(trigger: "idle"), now: 0).still(), [])
    }

    @Test func aStallPastAMinuteRestartsTheProgramInsteadOfReplayingIt() throws {
        let d = try Self.doc()
        var player = Player(d, request: Request(trigger: "execute"), now: 0)
        _ = player.sample(10 * 60_000)
        #expect(player.current.phase == "trade")
        #expect(player.current.start == 10 * 60_000)
    }

    @Test func theParseRefusesWhatIsNotADocument() {
        #expect(AppSceneChoreography(json: nil) == nil)
        #expect(AppSceneChoreography(json: .null) == nil)
        var schema = Self.fixture()
        schema["$schema"] = "cmux.particles/2"
        #expect(AppSceneChoreography(json: .object(schema)) == nil)
        var size = Self.fixture()
        size["particle"] = .object(["size": 0])
        #expect(AppSceneChoreography(json: .object(size)) == nil)
        var missing = Self.fixture()
        missing["triggers"] = .object(["read": .array(["missing"])])
        #expect(AppSceneChoreography(json: .object(missing)) == nil)
    }
}
