@testable import CmuxNextOnboarding
import CmuxNextPages
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// Home's Set Up cmux card replaces the first-run windows (goal next-first-run-setup): a first run starts
/// it and marks the Agents window and the CLI toast shown, so neither opens beside it (Bring your history opens
/// from the card's chat history row, which keeps that page's once flag);
/// an upgrade, or a channel that already showed the Agents window, never gets it; Hide ends it for good.
@MainActor @Suite(.serialized) struct FirstRunSetupTests {
    static let replaced = ["cli.install.offeredAtLaunch"]

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
        #expect(!defaults.bool(forKey: OnboardingWindowPresenter.historyShownKey), "Bring your history waits for the card's row")
        #expect(!OnboardingWindowPresenter.isFirstLaunch(defaults: defaults), "a started card is a finished first launch")

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
        #expect(defaults.bool(forKey: OnboardingWindowPresenter.historyShownKey), "Hide dismisses the chat history row with the card")
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

    /// Chats found on this Mac: the card's chat history row opens Bring your history on a click, and its once flag
    /// is set only once that page showed or the row was dismissed. None found: no row.
    @Test func theChatHistoryRowOpensBringYourHistory() async throws {
        let defaults = try defaults()
        let setup = FirstRunSetup(defaults: defaults)
        #expect(setup.begin(isFirstRun: true, replacedKeys: Self.replaced))
        let mac = PressLog()
        let environment = SetupCardEnvironment(account: { (false, nil) }, signInAccount: {}, cliState: { "missing" }, installCLI: { _ in },
                                               openAgents: {}, screenReader: { false }, historySources: { true },
                                               importHistory: { mac.imports += 1; return mac.importShows })
        let provider = SetupCardPageProvider(setup: setup, agents: nil, environment: environment)
        defer { provider.stop() }
        await until { provider.history != nil }
        #expect(provider.state["history"] == ["done": false])
        let importIt: JSONValue = ["action": ["kind": "importHistory"]]
        let click = { (at: TimeInterval) in PageCallContext(page: PageDescriptor.setupCard.id, userGesture: true, gestureEvent: at) }

        // The page did not show (a top page refused): the row stays.
        _ = try await provider.call("cmux.setup.run", params: importIt, context: click(1))
        #expect(mac.imports == 1 && !setup.historyDone && !defaults.bool(forKey: OnboardingWindowPresenter.historyShownKey))
        mac.importShows = true
        _ = try await provider.call("cmux.setup.run", params: importIt, context: click(2))
        #expect(mac.imports == 2 && setup.historyDone && defaults.bool(forKey: OnboardingWindowPresenter.historyShownKey))
        #expect(provider.state["history"] == ["done": true])
        #expect(setup.shows, "the rest of the card stays")

        let none = SetupCardPageProvider(setup: setup, agents: nil, environment: SetupCardEnvironment(
            account: { (false, nil) }, signInAccount: {}, cliState: { "missing" }, installCLI: { _ in }, openAgents: {}))
        defer { none.stop() }
        await until { none.history != nil }
        #expect(none.state["history"] == .null)
    }

    /// A `cmux` that is no cmux app's ("foreign", ``CLIInstallReport/setupRow(_:)``) is never installed over, even
    /// when the page asks on a real click.
    @Test func aForeignCmuxIsNeverReplaced() async throws {
        let setup = FirstRunSetup(defaults: try defaults())
        let mac = PressLog()
        let provider = SetupCardPageProvider(setup: setup, agents: nil, environment: SetupCardEnvironment(
            account: { (false, nil) }, signInAccount: {}, cliState: { "foreign" }, installCLI: { _ in mac.installs += 1 }, openAgents: {}))
        defer { provider.stop() }
        await until { provider.cli != nil }
        #expect(provider.state["cli"] == "foreign")
        await #expect(throws: PageError.self) {
            try await provider.call("cmux.setup.run", params: ["action": ["kind": "installCLI"]],
                                    context: PageCallContext(page: PageDescriptor.setupCard.id, userGesture: true, gestureEvent: 1))
        }
        #expect(mac.installs == 0)
    }

    /// The launch after the card started (pending, or ended) runs no first-run window: the old path would mark
    /// Bring your history shown with nothing shown and silently finish the card's chat history row.
    @Test func aLaterLaunchLeavesTheFirstRunStepsToTheCard() throws {
        let defaults = try defaults()
        #expect(FirstRunSetup(defaults: defaults).route(isFirstRun: true, replacedKeys: Self.replaced) == .startCard)
        let relaunch = FirstRunSetup(defaults: defaults)
        #expect(relaunch.route(isFirstRun: false, replacedKeys: Self.replaced) == .cardOwns)
        #expect(relaunch.shows && !relaunch.historyDone)
        #expect(!defaults.bool(forKey: OnboardingWindowPresenter.historyShownKey), "the chat history row stays")
        relaunch.end()
        #expect(FirstRunSetup(defaults: defaults).route(isFirstRun: false, replacedKeys: Self.replaced) == .cardOwns)

        // No card ever started (an upgrade, or VoiceOver at the first run): the first-run windows run as before.
        let upgrade = try self.defaults()
        #expect(FirstRunSetup(defaults: upgrade).route(isFirstRun: false, replacedKeys: Self.replaced) == .windows)
        #expect(FirstRunSetup(defaults: try self.defaults()).route(isFirstRun: true, replacedKeys: Self.replaced, screenReader: true) == .windows)
    }

    /// The command line row's install runs once: while it runs the row is "installing" and another click starts
    /// nothing; when it ends, the row shows what the PATH read found.
    @Test func theCommandLineInstallRunsOnce() async throws {
        let setup = FirstRunSetup(defaults: try defaults())
        let mac = PressLog()
        let provider = SetupCardPageProvider(setup: setup, agents: nil, environment: SetupCardEnvironment(
            account: { (false, nil) }, signInAccount: {}, cliState: { mac.cliAfter }, installCLI: { _ in
                mac.installs += 1
                await withCheckedContinuation { mac.installRuns = $0 }
            }, openAgents: {}))
        defer { provider.stop() }
        await until { provider.cli != nil }
        let install: JSONValue = ["action": ["kind": "installCLI"]]
        let click = { (at: TimeInterval) in PageCallContext(page: PageDescriptor.setupCard.id, userGesture: true, gestureEvent: at) }
        _ = try await provider.call("cmux.setup.run", params: install, context: click(1))
        await until { mac.installRuns != nil }
        #expect(provider.state["cli"] == "installing")
        await #expect(throws: PageError.self) { try await provider.call("cmux.setup.run", params: install, context: click(2)) }
        #expect(mac.installs == 1)

        mac.cliAfter = "installed"
        mac.installRuns?.resume()
        await until { !provider.cliInstalling }
        #expect(provider.state["cli"] == "installed")
    }

    /// Not Now on the chat history row answers it for good.
    @Test func notNowDismissesTheChatHistoryRow() async throws {
        let defaults = try defaults()
        let setup = FirstRunSetup(defaults: defaults)
        #expect(setup.begin(isFirstRun: true, replacedKeys: Self.replaced))
        let provider = SetupCardPageProvider(setup: setup, agents: nil, environment: SetupCardEnvironment(
            account: { (false, nil) }, signInAccount: {}, cliState: { "missing" }, installCLI: { _ in }, openAgents: {}, historySources: { true }))
        defer { provider.stop() }
        _ = try await provider.call("cmux.setup.run", params: ["action": ["kind": "declineHistory"]],
                                    context: PageCallContext(page: PageDescriptor.setupCard.id, userGesture: true, gestureEvent: 1))
        #expect(setup.historyDone && defaults.bool(forKey: OnboardingWindowPresenter.historyShownKey))
        #expect(FirstRunSetup(defaults: defaults).historyDone)
    }

    private func until(_ done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        // test-only: waits for the provider's one async read, bounded by the deadline
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
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
    var imports = 0
    var installs = 0
    var cliAfter = "missing"
    var installRuns: CheckedContinuation<Void, Never>?
    var importShows = false
}
