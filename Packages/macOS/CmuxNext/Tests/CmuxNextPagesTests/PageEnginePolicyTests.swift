@testable import CmuxNextPages
import CmuxNextSettings
import Testing

/// The one engine rule behind every cmux page view (``PageEnginePolicy``).
struct PageEnginePolicyTests {
    private static let plain = PageDescriptor(id: "test.plain", resource: "plain", namespaces: [])
    private static let dynamic = PageDescriptor(id: "test.dynamic", resource: "dynamic", namespaces: [], dynamicPrefixes: ["asset"])
    private static let agent = PageDescriptor(id: "cmux.agent", resource: "agent-pane", namespaces: [])

    @Test func aPlainPageFollowsTheChromiumDefault() {
        let decision = PageEnginePolicy(preference: .chromium, chromiumAvailable: true).decide(for: Self.plain, options: .standard)
        #expect(decision == .chromium)
        #expect(decision.webKitReason == nil)
    }

    /// Chromium asks the host for a page's generated files (``PageChromiumPage/resources``), so a
    /// page with dynamic prefixes shows there too.
    @Test func aPageWithGeneratedFilesFollowsTheChromiumDefault() {
        let decision = PageEnginePolicy(preference: .chromium, chromiumAvailable: true).decide(for: Self.dynamic, options: .standard)
        #expect(decision == .chromium)
    }

    @Test func thePersonsWebKitChoiceWinsForEveryPage() {
        for page in [Self.plain, Self.dynamic, Self.agent] {
            let decision = PageEnginePolicy(preference: .webkit, chromiumAvailable: true).decide(for: page, options: .standard)
            #expect(decision == .webKit(.personChoseWebKit))
        }
    }

    @Test func aPageThatCannotRunInChromiumNamesItsReason() {
        let policy = PageEnginePolicy(preference: .chromium, chromiumAvailable: true)
        #expect(policy.decide(for: Self.agent, options: .standard) == .webKit(.agentChat))
        #expect(policy.decide(for: Self.plain, options: PageEngineOptions(requiresWebKit: .transparentOverlay))
            == .webKit(.transparentOverlay))
        #expect(policy.decide(for: Self.plain, options: PageEngineOptions(requiresWebKit: .nativeHooks)) == .webKit(.nativeHooks))
    }

    @Test func theAgentChatSpikeLiftsOnlyTheAgentChatHold() {
        let policy = PageEnginePolicy(preference: .chromium, chromiumAvailable: true)
        let spike = PageEngineOptions(chromiumAgentChat: true)
        #expect(policy.decide(for: Self.agent, options: spike) == .chromium)
        // Only that one hold: a page the spike says nothing about keeps the reason it has.
        #expect(policy.decide(for: Self.dynamic,
                              options: PageEngineOptions(requiresWebKit: .transparentOverlay, chromiumAgentChat: true))
            == .webKit(.transparentOverlay))
        #expect(policy.decide(for: Self.agent, options: PageEngineOptions(requiresWebKit: .nativeHooks, chromiumAgentChat: true))
            == .webKit(.nativeHooks))
        #expect(PageEnginePolicy(preference: .webkit, chromiumAvailable: true).decide(for: Self.agent, options: spike)
            == .webKit(.personChoseWebKit))
        #expect(PageEnginePolicy(preference: .chromium, chromiumAvailable: false).decide(for: Self.agent, options: spike)
            == .webKit(.chromiumUnavailable))
    }

    /// `web-dev.json` reaches only WebKit's scheme handler, so a live override keeps every page there,
    /// after the person's choice and the page's own reason, which still name why.
    @Test func aLiveWebOverrideKeepsPagesOnWebKit() {
        let live = PageEnginePolicy(preference: .chromium, chromiumAvailable: true, liveWebOverride: true)
        #expect(live.decide(for: Self.plain, options: .standard) == .webKit(.liveWebOverride))
        #expect(live.decide(for: Self.dynamic, options: .standard) == .webKit(.liveWebOverride))
        #expect(live.decide(for: Self.agent, options: .standard) == .webKit(.agentChat))
        #expect(PageEnginePolicy(preference: .webkit, chromiumAvailable: true, liveWebOverride: true)
            .decide(for: Self.plain, options: .standard) == .webKit(.personChoseWebKit))
    }

    @Test func missingOrUnservedChromiumKeepsThePageOnWebKit() {
        #expect(PageEnginePolicy(preference: .chromium, chromiumAvailable: false).decide(for: Self.plain, options: .standard)
            == .webKit(.chromiumUnavailable))
        #expect(PageEnginePolicy(preference: .chromium, chromiumAvailable: true, chromiumServes: false)
            .decide(for: Self.plain, options: .standard) == .webKit(.notServedByChromium))
    }

    @Test func aPooledSpareIsWebKitWhateverThePolicySays() {
        #expect(PageEngineDecision.chromium.webKitOnly == PageEngineDecision(engine: .webKit))
        #expect(PageEngineDecision.webKit(.nativeHooks).webKitOnly == .webKit(.nativeHooks))
    }

    @Test func withoutAChromiumHostAPageIsOnWebKitForThatReason() {
        #expect(PageWebView.engineDecision(for: Self.plain, options: .standard, hosting: nil) == .webKit(.chromiumUnavailable))
        #expect(PageWebView.engineDecision(for: Self.dynamic, options: .standard, hosting: nil) == .webKit(.chromiumUnavailable))
    }
}
