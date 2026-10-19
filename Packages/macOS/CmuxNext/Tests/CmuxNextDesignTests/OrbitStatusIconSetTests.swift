import AppKit
@testable import CmuxNextDesign
import QuartzCore
import Testing

/// Leo 2026-10-18: a running row gets "a nice running animation on the left", like Claude Code's
/// four orange dots that slowly rotate and regroup. The Orbit set draws agent work as four dots that
/// turn around the slot and draw in and out together, in Claude's orange; every other state keeps
/// the Codex-like marks (Leo's team, 2026-10-14). It is the default set. Nothing in it blinks; at
/// the fastest Debug Settings periods the dots regroup at most twice a second (cx-sya4n, #21633),
/// and under Reduce Motion or the Static mode the static look draws instead (#21659).
@MainActor @Suite(.serialized) struct OrbitStatusIconSetTests {
    private static func plan(_ state: StatusIndicatorState, animates: Bool = true, isStatic: Bool = false) -> StatusIndicatorPlan {
        StatusIndicatorPlan.make(state, style: .arc, animates: animates, set: .orbit, isStatic: isStatic)
    }

    @Test func orbitIsTheDefaultSet() {
        #expect(StatusIconSet.tunable.defaultValue == .orbit)
    }

    @Test func workOrbitsInClaudesOrangeAndEveryOtherStateIsCodexLike() {
        #expect(Self.plan(.working) == StatusIndicatorPlan(glyph: .orbit, animation: .orbit, tint: .claude))
        let orange = StatusIndicatorLayer.Colors.claude.components ?? []
        #expect(orange.map { ($0 * 255).rounded() } == [215, 119, 87, 255])
        let others: [StatusIndicatorState] = [.idle, .success, .error, .waiting(kind: nil), .waiting(kind: .question),
                                              .waiting(kind: .permission), .busy(progress: nil), .working(progress: 0.4)]
        for state in others {
            #expect(Self.plan(state) == StatusIndicatorPlan.make(state, style: .arc, animates: true, set: .codex), "\(state)")
        }
    }

    @Test func stoppedTheDotsHoldTheirPlacesAndTheStaticLookTakesOver() {
        // Off screen or loops off: the four dots stand still where a turn starts.
        #expect(Self.plan(.working, animates: false) == StatusIndicatorPlan(glyph: .orbit, animation: nil, tint: .claude))
        // Reduce Motion or the Static mode: the static look's working glyph, as in every set.
        #expect(Self.plan(.working, isStatic: true) == StatusIndicatorPlan.make(.working, style: .arc, animates: true, set: .codex, isStatic: true))
    }

    @Test func theDotsTurnAndRegroupWithoutBlinkingAndNoFasterThanTwiceASecond() throws {
        let store = TunableStore.shared
        store.register(MotionTunables.all)
        store.activate(file: nil)
        // The fastest loop periods Debug Settings allows (a set value clamps to the tunable's range).
        let keys = MotionLoop.allCases.compactMap { MotionTunables.loops[$0]?.key }
        for key in keys { store.set(key, .number(0)) }
        defer { store.reset(keys) }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }

        let indicator = StatusIndicatorLayer()
        indicator.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        indicator.apply(Self.plan(.working), config: StatusIndicatorConfig(iconSet: .orbit))
        #expect(indicator.runningAnimation == .orbit)
        let replicator = try #require(indicator.orbitLayer)
        #expect(replicator.instanceCount == 4)
        let dot = try #require(replicator.sublayers?.first)
        let orbit = try #require(dot.animation(forKey: "orbit") as? CAKeyframeAnimation)
        // The dots move; nothing fades.
        #expect(orbit.keyPath == "position")
        #expect(dot.animation(forKey: "pulse") == nil && replicator.animationKeys() == nil)
        // One turn takes two pulse periods and the dots draw in and out twice a turn: a regroup at
        // most twice a second at the fastest pulse period (0.5 s).
        #expect(orbit.duration >= 2 * MotionLoop.pulse.minimumPeriod - 1e-6)
        let center = CGPoint(x: replicator.bounds.midX, y: replicator.bounds.midY)
        let radii = try #require(orbit.values?.map { value -> CGFloat in
            let point = (value as? NSValue)?.pointValue ?? .zero
            return hypot(point.x - center.x, point.y - center.y)
        })
        let inward = radii.indices.dropFirst().dropLast().filter { radii[$0] < radii[$0 - 1] && radii[$0] <= radii[$0 + 1] }
        #expect(inward.count == 2, "regroups per turn: \(inward.count)")
        // Drawn in, the dots still fit the slot; spread, they reach its edge.
        let side = indicator.debugGlyphRect.width
        #expect((radii.max() ?? 0) <= side / 2)
        #expect((radii.min() ?? 0) > 0)
    }

    @Test func aStoppedOrbitIsFourDotsOnTheAxes() throws {
        let indicator = StatusIndicatorLayer()
        indicator.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        indicator.apply(Self.plan(.working, animates: false), config: StatusIndicatorConfig(iconSet: .orbit))
        #expect(indicator.runningAnimation == nil)
        let dot = try #require(indicator.orbitLayer?.sublayers?.first)
        let center = try #require(indicator.orbitLayer).bounds
        #expect(abs(dot.position.x - center.midX) < 0.01, "the first dot sits on the vertical axis")
        #expect(dot.position.y > center.midY)
    }
}
