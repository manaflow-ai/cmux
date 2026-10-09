import AppKit
import Testing
@testable import CmuxNextDesign

/// cx-kxa2 (Lawrence 2026-10-08: "make sure we have better notif icons for
/// osc 7501 things ... make sure i can try a bunch of different icons so we
/// can search for the best one together"). Status icon candidate sets: the
/// default keeps today's marks exactly, every other set draws every state,
/// and an OSC 7501 blocked kind (permission, question, auth) reaches the plan.
@MainActor @Suite struct StatusIconSetTests {
    /// The states a set restyles, with the blocked kinds.
    static let states: [StatusIndicatorState] = [
        .working, .waiting(kind: .permission), .waiting(kind: .question), .waiting(kind: .auth), .waiting, .success, .error, .idle,
    ]

    static func table(_ set: StatusIconSet) -> [StatusIndicatorPlan] {
        states.map { StatusIndicatorPlan.make($0, style: .arc, animates: true, set: set) }
    }

    @Test func theDefaultSetIsTodaysDrawing() {
        #expect(StatusIconSet.tunable.defaultValue == .current)
        #expect(StatusIndicatorConfig().iconSet == .current)
        let all: [StatusIndicatorState] = Self.states + [.busy, .busy(progress: 0.3), .paused(progress: nil), .paused(progress: 0.5),
                                                         .working(progress: 0.4)]
        for state in all {
            for style in StatusIndicatorStyle.allCases {
                for animates in [true, false] {
                    #expect(StatusIndicatorPlan.make(state, style: style, animates: animates, set: .current)
                        == StatusIndicatorPlan.make(state, style: style, animates: animates), "\(state) \(style)")
                }
            }
        }
        // Today's marks, whatever the blocked kind.
        for kind in StatusBlockedKind.allCases {
            #expect(StatusIndicatorPlan.make(.waiting(kind: kind), style: .arc, animates: true)
                == StatusIndicatorPlan(glyph: .dot, animation: nil, tint: .attention))
        }
        #expect(StatusIndicatorPlan.make(.working, style: .arc, animates: true) == StatusIndicatorPlan(glyph: .dots, animation: .wave, tint: .accent))
        #expect(StatusIndicatorPlan.make(.error, style: .arc, animates: true) == StatusIndicatorPlan(glyph: .dot, animation: nil, tint: .danger))
        #expect(StatusIndicatorPlan.make(.success, style: .arc, animates: true) == StatusIndicatorPlan(glyph: .check, animation: nil, tint: .success))
    }

    @Test func atLeastEightSetsAndNoTwoDrawAlike() {
        #expect(StatusIconSet.allCases.count >= 8)
        let tables = StatusIconSet.allCases.map(Self.table)
        for i in tables.indices {
            for j in tables.indices where j > i {
                #expect(tables[i] != tables[j], "\(StatusIconSet.allCases[i]) and \(StatusIconSet.allCases[j]) draw the same")
            }
        }
        #expect(Set(StatusIconSet.allCases.map(\.tunableTitle)).count == StatusIconSet.allCases.count)
    }

    @Test func everyCandidateSetMarksEachBlockedKindApart() {
        for set in StatusIconSet.allCases where set != .current {
            let kinds = StatusBlockedKind.allCases.map { StatusIndicatorPlan.make(.waiting(kind: $0), style: .arc, animates: true, set: set) }
            #expect(Set(kinds).count == kinds.count, "\(set): permission, question and auth read apart")
            for state in Self.states {
                let plan = StatusIndicatorPlan.make(state, style: .arc, animates: true, set: set)
                #expect((plan.glyph == .none) == (state == .idle), "\(set) \(state)")
                // Colors come from the theme roles only.
                switch state {
                case .waiting: #expect(plan.tint == .attention, "\(set) \(state)")
                case .error: #expect(plan.tint == .danger)
                case .success: #expect(plan.tint == .success)
                case .working: #expect(plan.tint == .accent)
                default: break
                }
            }
            // Loading stays the loading style's; known progress stays a ring.
            for state: StatusIndicatorState in [.busy, .busy(progress: 0.3), .paused(progress: nil)] {
                #expect(StatusIndicatorPlan.make(state, style: .arc, animates: true, set: set)
                    == StatusIndicatorPlan.make(state, style: .arc, animates: true))
            }
            #expect(StatusIndicatorPlan.make(.working(progress: 0.4), style: .arc, animates: true, set: set).glyph == .ring(progress: 0.4))
            // Still hosts (occluded, Reduce Motion) animate nothing.
            for state in Self.states {
                #expect(StatusIndicatorPlan.make(state, style: .arc, animates: false, set: set).animation == nil)
            }
        }
    }

    @Test func theSetIsADebugSettingsTunable() {
        #expect(StatusIndicatorTunables.all.contains { $0.key == StatusIconSet.tunable.key })
        #expect(StatusIndicatorConfig(iconSet: .badges).iconSet == .badges)
    }

    /// The exported image comes from the same drawing as the live layer, so
    /// notifications can attach it: every set draws every visible state.
    @Test func everySetExportsAnImageForEveryState() throws {
        for set in StatusIconSet.allCases {
            for state in Self.states where state != .idle {
                let image = try #require(set.image(state: state, pointSize: 16, appearance: NSAppearance(named: .darkAqua)), "\(set) \(state)")
                #expect(image.size == NSSize(width: 16, height: 16))
                let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                #expect(Self.inked(cg) > 8, "\(set) \(state) draws ink")
            }
            #expect(set.image(state: .idle, pointSize: 16) == nil)
        }
        let kind = try #require(StatusIconSet.badges.image(state: .waiting, kind: .question, pointSize: 16)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        let plain = try #require(StatusIconSet.badges.image(state: .waiting, pointSize: 16)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(Self.pixels(kind) != Self.pixels(plain), "the kind argument reaches the drawing")
    }

    @Test func aCandidateMarkUsesOneLayerAndPulsesWhileWorking() {
        let indicator = StatusIndicatorLayer()
        indicator.colors = StatusIndicatorLayer.Colors(loading: CGColor(gray: 0.5, alpha: 1), attention: CGColor(gray: 0.6, alpha: 1),
                                                       danger: CGColor(gray: 0.3, alpha: 1), success: CGColor(gray: 0.7, alpha: 1))
        indicator.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        let config = StatusIndicatorConfig(iconSet: .badges)
        indicator.apply(.make(.waiting(kind: .auth), style: .arc, animates: true, set: .badges), config: config)
        #expect(indicator.liveSublayerCount == 1)
        if Motion.animatesLoops {
            indicator.apply(.make(.working, style: .arc, animates: true, set: .badges), config: config)
            #expect(indicator.runningAnimation != nil)
        }
        indicator.apply(.hidden, config: config)
        #expect(indicator.liveSublayerCount == 0)
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    static func inked(_ image: CGImage) -> Int {
        let bytes = pixels(image)
        return stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 50 }.count
    }
}
