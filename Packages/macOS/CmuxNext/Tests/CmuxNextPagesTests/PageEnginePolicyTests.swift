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

    @Test func thePersonsWebKitChoiceWinsForEveryPage() {
        for page in [Self.plain, Self.dynamic, Self.agent] {
            let decision = PageEnginePolicy(preference: .webkit, chromiumAvailable: true).decide(for: page, options: .standard)
            #expect(decision == .webKit(.personChoseWebKit))
        }
    }

    @Test func aPageThatCannotRunInChromiumNamesItsReason() {
        let policy = PageEnginePolicy(preference: .chromium, chromiumAvailable: true)
        #expect(policy.decide(for: Self.dynamic, options: .standard) == .webKit(.runtimeResources))
        #expect(policy.decide(for: Self.agent, options: .standard) == .webKit(.agentChat))
        #expect(policy.decide(for: Self.plain, options: PageEngineOptions(requiresWebKit: .transparentOverlay))
            == .webKit(.transparentOverlay))
        #expect(policy.decide(for: Self.plain, options: PageEngineOptions(requiresWebKit: .nativeHooks)) == .webKit(.nativeHooks))
    }

    @Test func missingOrUnservedChromiumKeepsThePageOnWebKit() {
        #expect(PageEnginePolicy(preference: .chromium, chromiumAvailable: false).decide(for: Self.plain, options: .standard)
            == .webKit(.chromiumUnavailable))
        #expect(PageEnginePolicy(preference: .chromium, chromiumAvailable: true, chromiumServes: false)
            .decide(for: Self.plain, options: .standard) == .webKit(.notServedByChromium))
    }

    @Test func aPooledSpareIsWebKitWhateverThePolicySays() {
        #expect(PageEngineDecision.chromium.webKitOnly == PageEngineDecision(engine: .webKit))
        #expect(PageEngineDecision.webKit(.runtimeResources).webKitOnly == .webKit(.runtimeResources))
    }

    @Test func withoutAChromiumHostAPageIsOnWebKitForThatReason() {
        #expect(PageWebView.engineDecision(for: Self.plain, options: .standard, hosting: nil) == .webKit(.chromiumUnavailable))
        #expect(PageWebView.engineDecision(for: Self.dynamic, options: .standard, hosting: nil) == .webKit(.runtimeResources))
    }
}
