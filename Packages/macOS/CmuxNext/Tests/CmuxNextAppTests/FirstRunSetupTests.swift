@testable import CmuxNextOnboarding
import CmuxNextTestSupport
import Foundation
import Testing

/// Home's Set Up cmux card replaces the first-run windows (goal next-first-run-setup): a first run starts
/// it and marks the Agents window, Bring your history and the CLI toast shown, so none opens beside it;
/// an upgrade, or a channel that already showed the Agents window, never gets it; Hide ends it for good.
@MainActor @Suite(.serialized) struct FirstRunSetupTests {
    static let replaced = [OnboardingWindowPresenter.historyShownKey, "cli.install.offeredAtLaunch"]

    func defaults() throws -> UserDefaults {
        let suite = "cmux-first-run-setup-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func aFirstRunShowsTheCardAndTheAgentsWindowNeverOpens() async throws {
        let defaults = try defaults()
        let setup = FirstRunSetup(defaults: defaults)
        #expect(!setup.shows)
        #expect(setup.begin(isFirstRun: true, replacedKeys: Self.replaced))
        #expect(setup.shows)
        for key in [OnboardingWindowPresenter.agentsShownKey] + Self.replaced { #expect(defaults.bool(forKey: key), "\(key) counts as shown") }

        // The Agents window, asked for after the card started, does not open even with an agent installed.
        var shown: [OnboardingModel.Step] = []
        let presenter = OnboardingWindowPresenter(makeModel: { step in OnboardingModel(services: MockOnboardingServices(), step: step) },
                                                  activeLook: nil, present: { shown.append($0.model.step) })
        let agent = OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude", auth: .signedOut)
        await presenter.showAgentsAtFirstRun(isFirstRun: true, source: MockAgentSignInSource(agents: [agent]), defaults: defaults)
        #expect(shown.isEmpty)

        // A relaunch keeps the card until Hide; then it never returns.
        #expect(FirstRunSetup(defaults: defaults).shows)
        #expect(!setup.begin(isFirstRun: true, replacedKeys: Self.replaced), "never twice")
        setup.end()
        #expect(!setup.shows)
        #expect(!FirstRunSetup(defaults: defaults).shows)
        #expect(!FirstRunSetup(defaults: defaults).begin(isFirstRun: true, replacedKeys: Self.replaced))
    }

    @Test func anUpgradeOrAChannelThatShowedTheAgentsWindowNeverGetsIt() throws {
        let upgrade = try defaults()
        #expect(!FirstRunSetup(defaults: upgrade).begin(isFirstRun: false, replacedKeys: Self.replaced))
        #expect(!upgrade.bool(forKey: OnboardingWindowPresenter.historyShownKey), "an upgrade marks nothing")

        let earlier = try defaults()
        earlier.set(true, forKey: OnboardingWindowPresenter.agentsShownKey)
        let setup = FirstRunSetup(defaults: earlier)
        #expect(!setup.begin(isFirstRun: true, replacedKeys: Self.replaced))
        #expect(!setup.shows)
    }
}
