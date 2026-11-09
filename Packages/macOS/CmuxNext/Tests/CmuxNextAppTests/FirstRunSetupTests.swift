@testable import CmuxNextOnboarding
import CmuxNextPages
import CmuxNextSettings
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

    /// VoiceOver presses the Agents window's Chromium page but not the card's WebKit one (manaflow-ai/cmux#37809).
    @Test func withVoiceOverAFirstRunShowsTheAgentsWindowNotTheCard() throws {
        let defaults = try defaults()
        let setup = FirstRunSetup(defaults: defaults)
        #expect(!setup.begin(isFirstRun: true, replacedKeys: Self.replaced, screenReader: true))
        #expect(!setup.shows)
        for key in [OnboardingWindowPresenter.agentsShownKey] + Self.replaced { #expect(!defaults.bool(forKey: key), "\(key) still shows") }
    }

    /// A press with no click or key behind it (VoiceOver's, in WebKit) is refused; with VoiceOver on, a row's
    /// press opens the Agents window instead and Hide takes the card away.
    @Test func aVoiceOverPressOnTheCardOpensTheAgentsWindow() async throws {
        let defaults = try defaults()
        let setup = FirstRunSetup(defaults: defaults)
        #expect(setup.begin(isFirstRun: true, replacedKeys: Self.replaced))
        let mac = PressLog()
        let environment = SetupCardEnvironment(account: { (false, nil) }, signInAccount: { mac.signIns += 1 }, cliState: { "missing" },
                                               installCLI: { _ in }, openAgents: { mac.opened += 1 }, screenReader: { mac.voiceOver })
        let provider = SetupCardPageProvider(setup: setup, agents: nil, environment: environment)
        defer { provider.stop() }
        let press = PageCallContext(page: PageDescriptor.setupCard.id)
        let signIn: JSONValue = ["action": ["kind": "signInAccount"]]

        await #expect(throws: PageError.self) { try await provider.call("cmux.setup.run", params: signIn, context: press) }
        #expect(mac.opened == 0 && mac.signIns == 0)

        mac.voiceOver = true
        _ = try await provider.call("cmux.setup.run", params: signIn, context: press)
        #expect(mac.opened == 1 && mac.signIns == 0, "the Agents window, not a sign-in no click asked for")
        _ = try await provider.call("cmux.setup.hide", params: [:], context: press)
        #expect(!setup.shows)

        // A real click still runs the row itself.
        let click = PageCallContext(page: PageDescriptor.setupCard.id, userGesture: true, gestureEvent: 1)
        _ = try await provider.call("cmux.setup.run", params: signIn, context: click)
        #expect(mac.signIns == 1 && mac.opened == 1)
    }
}

/// What the card's environment saw: VoiceOver's state, the Agents windows opened and the account sign-ins run.
@MainActor private final class PressLog {
    var voiceOver = false
    var opened = 0
    var signIns = 0
}
