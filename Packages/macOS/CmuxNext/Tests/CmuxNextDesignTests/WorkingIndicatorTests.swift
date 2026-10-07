import QuartzCore
import Testing
@testable import CmuxNextDesign

/// Agent work and page loading look clearly different
/// (WORKING-AND-LOADING-INDICATORS): working is three accent dots that move
/// one after another, page loading keeps the loading style (the thin ring by
/// default), needs input is a still attention dot.
struct WorkingIndicatorPlanTests {
    @Test func workingDrawsAccentDotsInEveryLoadingStyle() {
        for style in StatusIndicatorStyle.allCases {
            #expect(StatusIndicatorPlan.make(.working, style: style, animates: true)
                == StatusIndicatorPlan(glyph: .dots, animation: .wave, tint: .accent), "\(style)")
        }
    }

    @Test func workingNeverLooksLikeLoading() {
        for style in StatusIndicatorStyle.allCases {
            let working = StatusIndicatorPlan.make(.working, style: style, animates: true)
            let loading = StatusIndicatorPlan.make(.busy, style: style, animates: true)
            #expect(working.glyph != loading.glyph, "\(style)")
            #expect(working.tint != loading.tint, "\(style)")
        }
    }

    @Test func workingWithProgressDrawsAStillAccentRing() {
        #expect(StatusIndicatorPlan.make(.working(progress: 0.4), style: .arc, animates: true)
            == StatusIndicatorPlan(glyph: .ring(progress: 0.4), animation: nil, tint: .accent))
        #expect(StatusIndicatorState.working(progress: 2).progress == 1)
    }

    @Test func needsInputIsAStillAttentionDotInEveryStyle() {
        for style in StatusIndicatorStyle.allCases {
            #expect(StatusIndicatorPlan.make(.waiting, style: style, animates: true)
                == StatusIndicatorPlan(glyph: .dot, animation: nil, tint: .attention), "\(style)")
        }
    }

    /// Reduce Motion, hidden or occluded: the dots stay, still.
    @Test func stillWorkingKeepsTheDots() {
        let plan = StatusIndicatorPlan.make(.working, style: .arc, animates: false)
        #expect(plan == StatusIndicatorPlan(glyph: .dots, animation: nil, tint: .accent))
    }

    /// Working ranks with loading; a waiting agent wins over both.
    @Test func workingStacksWithLoadingAndUnderWaiting() {
        let working = StatusReport(id: "a", source: .agent, state: .working)
        let page = StatusReport(id: "b", source: .browser, state: .busy)
        let waiting = StatusReport(id: "c", source: .agent, state: .waiting)
        #expect(StatusStack.resolve([page, working]).state == .working)
        #expect(StatusStack.resolve([page, working, waiting]).state == .waiting)
    }

    @Test func onlyLoadingAndWorkingReplaceTheTabIcon() {
        #expect(StatusIndicatorState.working.replacesTabIcon)
        #expect(StatusIndicatorState.busy.replacesTabIcon)
        #expect(StatusIndicatorState.paused(progress: 0.2).replacesTabIcon)
        #expect(!StatusIndicatorState.waiting.replacesTabIcon)
        #expect(!StatusIndicatorState.working.isLoading)
    }
}

/// The working dots read on the tab strip and the sidebar in dark and light
/// Ghostty themes: the accent tint is the theme foreground (`textPrimary`),
/// never fainter than the loading ring's secondary text.
struct WorkingIndicatorContrastTests {
    private func tokens(_ name: String) -> ThemeTokens {
        ThemeTokens.derive(from: ThemeFixtures.all.first { $0.0 == name }!.1)
    }

    private func contrast(_ color: ThemeRGB, over background: ThemeRGB) -> Double {
        let base = background.withAlpha(1)
        return color.composited(over: base).contrast(with: base)
    }

    @Test(arguments: ThemeFixtures.all.map(\.0))
    func dotsAreAtLeastAsStrongAsTheLoadingRing(_ name: String) {
        let t = tokens(name)
        for background in [t.stripBackground, t.sidebarBackground] {
            #expect(contrast(t.textPrimary, over: background) >= contrast(t.textSecondary, over: background), "\(name)")
        }
    }

    @Test(arguments: ThemeFixtures.all.map(\.0).filter { $0 != "low contrast" })
    func dotsMeetNonTextContrastInRealThemes(_ name: String) {
        let t = tokens(name)
        for background in [t.stripBackground, t.sidebarBackground] {
            // WCAG non-text contrast: 3:1.
            #expect(contrast(t.textPrimary, over: background) >= 3, "\(name) \(contrast(t.textPrimary, over: background))")
        }
    }
}

/// The layer draws the dots with one sublayer and runs the wave in the
/// render server.
@MainActor
struct WorkingIndicatorLayerTests {
    func make() -> StatusIndicatorLayer {
        let indicator = StatusIndicatorLayer()
        indicator.colors = StatusIndicatorLayer.Colors(loading: CGColor(gray: 0.5, alpha: 1), attention: CGColor(gray: 0.6, alpha: 1),
                                                       danger: CGColor(gray: 0.3, alpha: 1), success: CGColor(gray: 0.7, alpha: 1),
                                                       accent: CGColor(gray: 0.9, alpha: 1))
        indicator.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        return indicator
    }

    @Test func dotsUseOneSublayerAndIdleReleasesIt() throws {
        let indicator = make()
        indicator.apply(.make(.working, style: .arc, animates: false), config: StatusIndicatorConfig())
        #expect(indicator.liveSublayerCount == 1)
        let replicator = try #require(indicator.layer.sublayers?.first as? CAReplicatorLayer)
        #expect(replicator.instanceCount == 3)
        let dot = try #require(replicator.sublayers?.first as? CAShapeLayer)
        #expect(dot.fillColor == CGColor(gray: 0.9, alpha: 1))
        indicator.apply(.hidden, config: StatusIndicatorConfig())
        #expect(indicator.liveSublayerCount == 0)
    }

    @Test func theWaveRunsOnlyWhileAnimating() {
        guard Motion.animatesLoops else { return }
        let indicator = make()
        indicator.apply(.make(.working, style: .arc, animates: true), config: StatusIndicatorConfig())
        #expect(indicator.runningAnimation == .wave)
        indicator.apply(.make(.working, style: .arc, animates: false), config: StatusIndicatorConfig())
        #expect(indicator.runningAnimation == nil)
    }
}
