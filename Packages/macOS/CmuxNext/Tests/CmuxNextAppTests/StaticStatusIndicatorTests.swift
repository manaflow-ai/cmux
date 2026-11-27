import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Leo 2026-10-13 (cx-sya4n): blinking and pulsing lights give a teammate headaches. The static
/// look (`appearance.statusIndicator.animation: "static"`, or Reduce Motion) reaches every
/// surface: tabs draw a still mark (never a dot told apart by color alone), the pane attention
/// ring is the steady ring, the agent pane's page hears it, and every indicator names its state
/// in its tooltip and VoiceOver label, in every look.
@MainActor @Suite(.serialized) struct StaticStatusIndicatorTests {
    static let states: [(name: String, state: StatusIndicatorState)] = [
        ("working", .working(progress: nil)), ("busy", .busy(progress: nil)), ("paused", .paused(progress: nil)),
        ("waiting", .waiting(kind: nil)), ("permission", .waiting(kind: .permission)), ("question", .waiting(kind: .question)),
        ("auth", .waiting(kind: .auth)), ("error", .error), ("done", .success),
    ]

    /// Every animation on `layer` and the layers under it that repeats.
    static func loops(under layer: CALayer?) -> [String] {
        guard let layer else { return [] }
        let own = (layer.animationKeys() ?? []).filter { key in
            guard let animation = layer.animation(forKey: key) else { return false }
            return animation.repeatCount >= .greatestFiniteMagnitude || animation.repeatDuration > 0
        }
        return own + ((layer.sublayers ?? []) + [layer.mask].compactMap { $0 }).flatMap { loops(under: $0) }
    }

    /// Turns the static look on through the setting and applies it now.
    private static func withStatic(shapes: Bool = false, _ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let before = design.statusIndicator
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(StatusIndicatorTunables.all)
        defer {
            design.statusIndicator = before
            store.set(StatusIndicatorPlan.staticShapes.key, nil)
            StatusIndicatorAppearance.shared.apply(StatusIndicatorConfig.current)
        }
        design.statusIndicator.animation = .static
        store.set(StatusIndicatorPlan.staticShapes.key, .bool(shapes))
        StatusIndicatorAppearance.shared.apply(StatusIndicatorConfig.current)
        try body()
    }

    private static func tabs() -> [(name: String, cell: TabCell)] {
        func tab(_ name: String, _ change: (inout TabItem) -> Void) -> (String, TabCell) {
            var item = TabItem(id: CmuxNextTabs.TabID("t-\(name)"), title: name)
            change(&item)
            return (name, TabCell(item: item))
        }
        return [
            tab("working") { $0.indicator = .working(progress: nil) },
            tab("busy") { $0.indicator = .busy(progress: nil) },
            tab("waiting") { $0.status = .needsInput },
            tab("permission") { $0.status = .needsInput; $0.blockedKind = .permission },
            tab("question") { $0.status = .needsInput; $0.blockedKind = .question },
            tab("auth") { $0.status = .needsInput; $0.blockedKind = .auth },
            tab("error") { $0.status = .failure },
            tab("done") { $0.status = .success },
        ]
    }

    @Test func everyIndicatorNamesItsStateInEveryLook() {
        var labels: [String: String] = [:]
        for (name, state) in Self.states {
            let view = StatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            view.configure(state)
            let label = view.themedToolTip ?? ""
            #expect(!label.isEmpty, "\(name): the mark has no tooltip")
            #expect(view.accessibilityLabel() == label, "\(name): VoiceOver does not read \"\(label)\"")
            labels[name] = label
        }
        #expect(Set(labels.values).count == Self.states.count, "two states share a label: \(labels)")
        #expect(StatusIndicatorState.idle.shortLabel == nil)
    }

    @Test func staticTabsDrawAStillMarkForEveryState() throws {
        try Self.withStatic {
            for (name, cell) in Self.tabs() {
                let plan = try #require((cell.spinnerLayer ?? cell.statusGlyphLayer)?.plan, "\(name): the tab draws no mark")
                #expect(plan.animation == nil, "\(name) animates on its tab")
                #expect(Self.loops(under: cell.layer) == [], "\(name) loops on its tab")
                if case .dot = plan.glyph { Issue.record("\(name): a dot told apart by color alone") }
            }
        }
    }

    @Test func theShapesToggleGivesEveryTabStateItsOwnMark() throws {
        try Self.withStatic(shapes: true) {
            var glyphs: [String: StatusIndicatorPlan.Glyph] = [:]
            for (name, cell) in Self.tabs() {
                glyphs[name] = try #require((cell.spinnerLayer ?? cell.statusGlyphLayer)?.plan, "\(name)").glyph
            }
            #expect(Set(glyphs.values).count == glyphs.count, "two tab states share a mark: \(glyphs)")
        }
    }

    @Test func theAttentionRingIsSteadyInTheStaticLook() {
        Self.withStatic {
            Motion.reduceMotionOverride = false
            defer { Motion.reduceMotionOverride = nil }
            var attention = AttentionSettings()
            for style in [AttentionStyle.blink, .pulse] {
                attention.style = style
                guard let animation = Motion.indicators.attentionAnimation(attention) else { continue }
                #expect(animation.repeatCount == 0 && animation.repeatDuration == 0, "the attention ring loops (\(style))")
                if let frames = animation as? CAKeyframeAnimation {
                    #expect((frames.values?.count ?? 0) <= 3, "the attention ring blinks (\(style))")
                }
            }
        }
    }

    /// The agent pane's web page hears the static look through its theme (`statusIndicators`,
    /// `data-status-indicators` on the page root): Static, or Reduce Motion with Animated picked.
    @Test func theAgentPaneHearsTheStaticLook() {
        let design = DesignSettings.shared
        let before = design.statusIndicator
        defer {
            design.statusIndicator = before
            Motion.reduceMotionOverride = nil
        }
        func look() -> String? { AgentPaneTheme.values(.unresolved)["statusIndicators"] as? String }
        Motion.reduceMotionOverride = false
        design.statusIndicator.animation = .animated
        #expect(look() == "animated")
        design.statusIndicator.animation = .static
        #expect(look() == "static")
        design.statusIndicator.animation = .animated
        Motion.reduceMotionOverride = true
        #expect(look() == "static")
    }
}
