import AppKit
@testable import CmuxNextOnboarding
import CmuxNextPages
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// Home's Set Up cmux card replaces the first-run windows (goal next-first-run-setup): a first run starts
/// it and marks the Agents window and the CLI toast shown, so neither opens beside it;
/// an upgrade, or a channel that already showed the Agents window, never starts it automatically; Hide ends it until reopened.
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
        #expect(defaults.bool(forKey: OnboardingWindowPresenter.historyShownKey), "Hide finishes this Mac's first launch")
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

    @Test func theSetUpActionReopensAnEndedCardWithItsAnsweredRows() throws {
        let defaults = try defaults()
        let setup = FirstRunSetup(defaults: defaults)
        #expect(setup.begin(isFirstRun: true, replacedKeys: Self.replaced))
        setup.end()
        #expect(!setup.shows)

        setup.reopen()
        #expect(setup.shows)
        #expect(defaults.string(forKey: FirstRunSetup.stateKey) == "reopened")
        #expect(FirstRunSetup(defaults: defaults).shows)
    }

    @Test func explicitSetupWorksWhenAutomaticOnboardingIsSkipped() throws {
        let defaults = try defaults()
        let setup = FirstRunSetup(defaults: defaults, skipsOnboarding: true)
        #expect(!setup.begin(isFirstRun: true, replacedKeys: Self.replaced))
        setup.reopen()
        #expect(setup.shows)
        for key in [OnboardingWindowPresenter.agentsShownKey] + Self.replaced {
            #expect(!defaults.bool(forKey: key), "reopening never changes first-run markers")
        }
        setup.end()
        #expect(!setup.shows)
    }

    @Test(arguments: [false, true])
    func completedRowsAutoHideOnlyOnFirstRun(reopened: Bool) async throws {
        let setup = FirstRunSetup(defaults: try defaults())
        #expect(setup.begin(isFirstRun: true, replacedKeys: Self.replaced))
        if reopened { setup.end(); setup.reopen() }
        let source = MockAgentSignInSource(agents: [OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude", auth: .signedIn)])
        let provider = SetupCardPageProvider(setup: setup, agents: source, environment: SetupCardEnvironment(
            account: { (true, nil) }, signInAccount: {}, cliState: { "installed" }, installCLI: { _ in }, openAgents: {}))
        defer { provider.stop() }
        await until { provider.agents.loaded && provider.cli != nil }
        #expect(provider.allDone)
        var received = false
        let subscription = try await provider.subscribe("cmux.setup.changed", filter: [:], context: click(1)) { _ in received = true }
        defer { subscription.cancel() }
        await until { received }
        #expect(received)
        #expect(setup.shows == reopened, "an explicit visit keeps completed rows visible")
        #expect(provider.state["cli"] == "installed")
        #expect(provider.state["agents"]?.arrayValue?.first?["state"] == "signedIn")
        _ = try await provider.call("cmux.setup.hide", params: [:], context: click(2))
        #expect(!setup.shows, "Hide still ends either kind of visit")
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

    /// The launch after the card started (pending, or ended) runs no first-run window, and finishes no first launch
    /// before the card ends.
    @Test func aLaterLaunchLeavesTheFirstRunStepsToTheCard() throws {
        let defaults = try defaults()
        #expect(FirstRunSetup(defaults: defaults).route(isFirstRun: true, replacedKeys: Self.replaced) == .startCard)
        let relaunch = FirstRunSetup(defaults: defaults)
        #expect(relaunch.route(isFirstRun: false, replacedKeys: Self.replaced) == .cardOwns)
        #expect(relaunch.shows)
        #expect(!defaults.bool(forKey: OnboardingWindowPresenter.historyShownKey), "the first launch ends with the card")
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

    /// An install that failed, then a read that finds the agent installed after all: the row follows the read
    /// (Sign In), not the stale failure (an Install with nothing to do).
    @Test func aFreshReadWinsOverAnEarlierFailedInstall() async throws {
        let setup = FirstRunSetup(defaults: try defaults())
        let source = MockAgentSignInSource(agents: [
            OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude", auth: .unknown, installed: false)])
        source.installFails = "the installer exited 1"
        let provider = SetupCardPageProvider(setup: setup, agents: source, environment: SetupCardEnvironment(
            account: { (false, nil) }, signInAccount: {}, cliState: { "missing" }, installCLI: { _ in }, openAgents: {}))
        defer { provider.stop() }
        await until { provider.agents.loaded }
        provider.agents.install("claude")
        await until { provider.agents.installs["claude"] != .installing }
        #expect(provider.state["agents"]?.arrayValue?.first?["state"] == "failed")

        source.agents = [OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude", auth: .signedOut)]
        provider.agents.refresh(recheck: true)
        await until { provider.agents.agents.contains { $0.id == "claude" } }
        #expect(provider.state["agents"]?.arrayValue?.first?["state"] == "signedOut")
    }

    /// Claude Code's Keychain login reads as unknown until a session proves it. Opening its login from the card
    /// proves nothing (it may be cancelled), so the row waits for the person to say it finished, then the card can end.
    @Test func aKeychainLoginFinishesOnlyWhenThePersonConfirmsIt() async throws {
        let setup = FirstRunSetup(defaults: try defaults())
        #expect(setup.begin(isFirstRun: true, replacedKeys: Self.replaced))
        let source = MockAgentSignInSource(agents: [OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude", auth: .unknown)])
        let provider = SetupCardPageProvider(setup: setup, agents: source, environment: SetupCardEnvironment(
            account: { (true, nil) }, signInAccount: {}, cliState: { "installed" }, installCLI: { _ in }, openAgents: {}))
        defer { provider.stop() }
        await until { provider.agents.loaded && provider.cli != nil }
        #expect(provider.state["agents"]?.arrayValue?.first?["state"] == "signedOut")

        // The login opens, then is cancelled: the sign-in still reads as unknown.
        _ = try await provider.call("cmux.setup.run", params: ["action": ["kind": "signInAgent", "id": "claude"]], context: click(1))
        await until { provider.agents.loginsOpened.contains("claude") }
        provider.agents.refresh(recheck: true)
        await until { !provider.agents.loading }
        #expect(provider.state["agents"]?.arrayValue?.first?["state"] == "unverified")
        #expect(!provider.allDone && setup.shows, "an opened login is no proof: the card stays")

        _ = try await provider.call("cmux.setup.run", params: ["action": ["kind": "confirmAgent", "id": "claude"]], context: click(2))
        #expect(provider.state["agents"]?.arrayValue?.first?["state"] == "signedIn")
        #expect(provider.allDone)
    }

    /// I'm Signed In does nothing for an agent whose login never opened here.
    @Test func confirmingWithoutAnOpenedLoginDoesNothing() async throws {
        let setup = FirstRunSetup(defaults: try defaults())
        let source = MockAgentSignInSource(agents: [OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude", auth: .unknown)])
        let provider = SetupCardPageProvider(setup: setup, agents: source, environment: SetupCardEnvironment(
            account: { (true, nil) }, signInAccount: {}, cliState: { "installed" }, installCLI: { _ in }, openAgents: {}))
        defer { provider.stop() }
        await until { provider.agents.loaded && provider.cli != nil }
        _ = try await provider.call("cmux.setup.run", params: ["action": ["kind": "confirmAgent", "id": "claude"]], context: click(1))
        #expect(provider.agents.confirmedLogins.isEmpty)
        #expect(provider.state["agents"]?.arrayValue?.first?["state"] == "signedOut")
        #expect(!provider.allDone)
    }

    private func click(_ event: TimeInterval) -> PageCallContext {
        PageCallContext(page: PageDescriptor.setupCard.id, userGesture: true, gestureEvent: event)
    }

    /// Every card this launch shares one agents model: a card made again mid-install (another Home conversation)
    /// shows the install running, starts no second one, and the install's sign-in still runs when it ends.
    @Test func aCardMadeAgainKeepsTheRunningInstall() async throws {
        let setup = FirstRunSetup(defaults: try defaults())
        let source = HeldInstallSource()
        let environment = SetupCardEnvironment(account: { (false, nil) }, signInAccount: {}, cliState: { "missing" }, installCLI: { _ in },
                                               openAgents: {})
        let first = SetupCardPageProvider(setup: setup, agents: source, environment: environment)
        await until { first.agents.loaded }
        let click = { (at: TimeInterval) in PageCallContext(page: PageDescriptor.setupCard.id, userGesture: true, gestureEvent: at) }
        _ = try await first.call("cmux.setup.run", params: ["action": ["kind": "installAgent", "id": "claude"]], context: click(1))
        await until { source.running != nil }
        first.stop()

        let again = SetupCardPageProvider(setup: setup, agents: source, environment: environment)
        defer { again.stop() }
        #expect(again.agents === first.agents)
        #expect(again.agents.installs["claude"] == .installing)
        _ = try await again.call("cmux.setup.run", params: ["action": ["kind": "installAgent", "id": "codex"]], context: click(2))
        #expect(source.installsRun == ["claude"], "one install at a time, across cards")

        source.running?.resume()
        await until { !source.signIns.isEmpty }
        #expect(source.signIns == ["claude"], "the install's sign-in runs after the card was made again")
    }

    /// First-run findings rows 1 and 4: first-run onboarding is off, so a fresh Mac opened straight into Home and
    /// Chief refused every message with an internal error. Home's Chief chat now shows the card in its Chief form
    /// (the agents row alone, for Claude Code, which Chief answers through) while Claude Code is missing or signed
    /// out, whatever the onboarding switch says; it leaves once Claude Code is signed in. A read with no evidence
    /// (acpmux did not answer, a Keychain login read as unknown) never shows it, and Hide puts it away for this launch.
    @Test func chiefWithoutItsAgentShowsTheAgentCardWithOnboardingOff() async throws {
        let setup = FirstRunSetup(defaults: try defaults(), skipsOnboarding: true)
        let missing = OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude", auth: .unknown, installed: false)
        let codex = OnboardingAgent(id: "codex", name: "Codex", brand: "codex", auth: .signedIn)
        let source = MockAgentSignInSource(agents: [missing, codex])
        let model = setup.agents(source: source)
        #expect(!setup.needsChiefAgent, "nothing read yet is no evidence")
        model.refresh(recheck: false)
        await until { model.loaded }
        #expect(!setup.shows, "the full card stays off")
        #expect(setup.needsChiefAgent, "Codex signed in does not answer for Chief")

        let environment = SetupCardEnvironment(account: { (false, nil) }, signInAccount: {}, cliState: { "missing" }, installCLI: { _ in },
                                               openAgents: {})
        let provider = SetupCardPageProvider(setup: setup, agents: source, environment: environment, forChief: true)
        defer { provider.stop() }
        #expect(provider.state["forChief"] == true)
        #expect(provider.state["agents"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == ["claude"])
        #expect(provider.state["agents"]?.arrayValue?.first?["state"] == "missing")

        for (auth, needs) in [(OnboardingAgent.Auth.signedOut, true), (.expired, true), (.unknown, false), (.signedIn, false)] {
            source.agents = [OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude", auth: auth), codex]
            model.refresh(recheck: true)
            await until { !model.loading }
            #expect(setup.needsChiefAgent == needs, "Claude Code \(auth)")
        }
        #expect(provider.allDone, "Claude Code signed in finishes the Chief card")

        source.agents = []
        model.refresh(recheck: true)
        await until { !model.loading }
        #expect(!setup.needsChiefAgent, "acpmux answered nothing: no evidence")

        source.agents = [missing]
        model.refresh(recheck: true)
        await until { !model.loading }
        #expect(setup.needsChiefAgent)
        _ = try await provider.call("cmux.setup.hide", params: [:], context: click(1))
        #expect(!setup.needsChiefAgent, "Hide puts it away for this launch")
        #expect(FirstRunSetup(defaults: try defaults(), skipsOnboarding: true).shows == false)
    }

    /// Classic stable's save (no workspaces), as the launch's migration asks it: the app reads the daemon's preview
    /// into this offer (`AppOnboardingServices.classicOffer`), so the test's preview is the offer itself.
    private static let plan = FirstRunSetup.ClassicOffer(workspaces: 0, app: "cmux", savedAt: 1_793_000_000, running: false)
    private static let quiet = SetupCardEnvironment(account: { (true, nil) }, signInAccount: {}, cliState: { "installed" }, installCLI: { _ in },
                                                    openAgents: {})

    /// The launch's migration through the card (``FirstRunSetup/classicMigration(seam:offer:dialog:screenReader:imported:_:)``): it asks the plan
    /// once `ask` resumes, and returns the answer; `dialog` counts the dialog's asks.
    /// `screenReader` is VoiceOver when it asks; with `holds`, the import waits after the answer until `finish()`
    /// (failing when `fails`), as a real import's backup and workspaces take a moment.
    @MainActor private final class LaunchRun {
        struct ImportFailed: Error {}
        var dialogs = 0
        var gate: CheckedContinuation<Void, Never>?
        var gated = false
        var held: CheckedContinuation<Void, Never>?
        var holds = false
        var fails = false
        var madeNothing = false

        func start(_ setup: FirstRunSetup, seam: (@MainActor (FirstRunSetup.ClassicOffer) async -> ClassicImportAnswer)? = nil,
                   screenReader: Bool = false) -> Task<ClassicImportAnswer?, Never> {
            Task { @MainActor in
                try? await setup.classicMigration(seam: seam, offer: { $0 }, dialog: { [self] _ in dialogs += 1; return .declined },
                                                  screenReader: { screenReader }, imported: { [self] _ in !madeNothing }) { confirm in
                    await withCheckedContinuation { gate = $0; gated = true }
                    let answer = await confirm(FirstRunSetupTests.plan)
                    if holds { await withCheckedContinuation { held = $0 } }
                    if fails { throw ImportFailed() }
                    return answer
                }
            }
        }

        func ask() {
            gate?.resume()
            gate = nil
        }

        func finish() {
            held?.resume()
            held = nil
        }
    }

    /// A Classic user's first run is the same card: the launch's classic import asks on its cmux Classic row (the
    /// app, its save time, whether it is open, what Import also does), and the row's own click answers it, Import
    /// or Skip (a No the migration keeps); the row then reads the answer and no dialog asked.
    @Test func theLaunchsClassicImportAsksOnTheCardsClassicRow() async throws {
        for (kind, answer, wire) in [("importClassic", ClassicImportAnswer.accepted, "imported"), ("declineClassic", .declined, "declined")] {
            let setup = FirstRunSetup(defaults: try defaults())
            #expect(setup.begin(isFirstRun: true, replacedKeys: Self.replaced))
            let provider = SetupCardPageProvider(setup: setup, agents: nil, environment: Self.quiet)
            defer { provider.stop() }
            let run = LaunchRun()
            let launch = run.start(setup)
            await until { run.gated }
            #expect(provider.state["classic"] == .null, "no row before the migration asks")
            run.ask()
            await until { setup.classic != nil }
            let row = try #require(provider.state["classic"]?.objectValue)
            #expect(row["workspaces"] == .number(0) && row["app"] == .string("cmux") && row["savedAt"] == .number(1_793_000_000_000))
            #expect(row["running"] == .bool(false) && row["resumes"] == .bool(false) && row["answered"] == nil)

            // Only the person's own click answers it.
            await #expect(throws: PageError.self) {
                try await provider.call("cmux.setup.run", params: ["action": ["kind": .string(kind)]],
                                        context: PageCallContext(page: PageDescriptor.setupCard.id, userGesture: false))
            }
            #expect(setup.classicAnswer == nil)
            _ = try await provider.call("cmux.setup.run", params: ["action": ["kind": .string(kind)]], context: click(1))
            #expect(await launch.value == answer)
            #expect(run.dialogs == 0)
            #expect(provider.state["classic"]?.objectValue?["answered"] == .string(wire))
        }
    }

    /// The card never ends before the launch's migration decided whether it asks, nor while it asks; Hide leaves the
    /// ask unanswered (only Skip is a No, so the next launch asks again), and with the card gone the dialog asks.
    @Test func theCardWaitsForTheClassicAnswerAndHideLeavesItUnanswered() async throws {
        let setup = FirstRunSetup(defaults: try defaults())
        #expect(setup.begin(isFirstRun: true, replacedKeys: Self.replaced))
        let agent = OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude", auth: .signedIn)
        let provider = SetupCardPageProvider(setup: setup, agents: MockAgentSignInSource(agents: [agent]), environment: Self.quiet)
        defer { provider.stop() }
        await until { provider.agents.loaded && provider.state["cli"] == .string("installed") }
        #expect(provider.allDone, "every row done with no migration running")

        let run = LaunchRun()
        let launch = run.start(setup)
        await until { run.gated }
        #expect(!provider.allDone, "the migration has not decided yet")
        run.ask()
        await until { setup.classic != nil }
        #expect(!provider.allDone, "the cmux Classic row still asks")
        _ = try await provider.call("cmux.setup.hide", params: [:], context: click(1))
        #expect(await launch.value == .unanswered, "Hide is no answer: only Skip is a No")
        #expect(!setup.shows && run.dialogs == 0)

        let after = LaunchRun()
        let again = after.start(setup)
        await until { after.gated }
        after.ask()
        #expect(await again.value == .declined && after.dialogs == 1, "with no card, the launch asks with its dialog")
    }

    /// A card that shows but is drawn nowhere (its page could not be made, or its window closed mid-ask) never holds
    /// the migration: with no card drawn the dialog asks at once, and the last card closing hands an ask to it.
    @Test func withNoCardDrawnTheDialogAsks() async throws {
        let setup = FirstRunSetup(defaults: try defaults(), cardWait: .milliseconds(50))
        #expect(setup.begin(isFirstRun: true, replacedKeys: Self.replaced))
        let none = LaunchRun()
        let first = none.start(setup)
        await until { none.gated }
        none.ask()
        #expect(await first.value == .declined && none.dialogs == 1 && setup.classic == nil, "no card drawn in time: the dialog")

        let provider = SetupCardPageProvider(setup: setup, agents: nil, environment: Self.quiet)
        let closing = LaunchRun()
        let second = closing.start(setup)
        await until { closing.gated }
        closing.ask()
        await until { setup.classic != nil }
        provider.stop()
        provider.stop()
        #expect(await second.value == .declined && closing.dialogs == 1, "the card closed mid-ask: the dialog")
        #expect(setup.classic == nil && setup.shows)
    }

    /// Import says Imported only once the migration brought the workspaces: Importing while it runs (the card does
    /// not end), and Not imported when it failed, so a failed import never keeps a checkmark.
    @Test func theClassicRowSaysImportedOnlyWhenTheImportFinished() async throws {
        for (fails, wire) in [(false, "imported"), (true, "failed")] {
            let setup = FirstRunSetup(defaults: try defaults())
            #expect(setup.begin(isFirstRun: true, replacedKeys: Self.replaced))
            let agent = OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude", auth: .signedIn)
            let provider = SetupCardPageProvider(setup: setup, agents: MockAgentSignInSource(agents: [agent]), environment: Self.quiet)
            defer { provider.stop() }
            await until { provider.agents.loaded && provider.state["cli"] == .string("installed") }
            let run = LaunchRun()
            (run.holds, run.fails) = (true, fails)
            let launch = run.start(setup)
            await until { run.gated }
            run.ask()
            await until { setup.classic != nil }
            _ = try await provider.call("cmux.setup.run", params: ["action": ["kind": .string("importClassic")]], context: click(1))
            await until { run.held != nil }
            #expect(provider.state["classic"]?.objectValue?["answered"] == .string("importing"))
            #expect(!provider.allDone, "the card stays while the import runs")
            run.finish()
            #expect(await launch.value == (fails ? nil : .accepted))
            #expect(provider.state["classic"]?.objectValue?["answered"] == .string(wire))
            #expect(provider.allDone, "answered and finished either way")
        }
    }

    /// With VoiceOver on, the import asks with its dialog even on a card an earlier launch left pending: VoiceOver
    /// cannot press the card's WebKit buttons.
    @Test func withVoiceOverAPendingCardLeavesTheAskToTheDialog() async throws {
        let store = try defaults()
        #expect(FirstRunSetup(defaults: store).begin(isFirstRun: true, replacedKeys: Self.replaced))
        let relaunched = FirstRunSetup(defaults: store)
        #expect(relaunched.route(isFirstRun: false, replacedKeys: Self.replaced, screenReader: true) == .cardOwns && relaunched.shows)
        let provider = SetupCardPageProvider(setup: relaunched, agents: nil, environment: Self.quiet)
        defer { provider.stop() }
        let run = LaunchRun()
        let launch = run.start(relaunched, screenReader: true)
        await until { run.gated }
        run.ask()
        #expect(await launch.value == .declined && run.dialogs == 1 && relaunched.classic == nil)
    }

    /// A cold launch draws the card once Home's chat starts, which can be after the migration asks: the ask waits for
    /// that card and shows on its row, and the dialog never asks.
    @Test func aCardDrawnAfterTheAskStartedStillAsksOnItsRow() async throws {
        let setup = FirstRunSetup(defaults: try defaults())
        #expect(setup.route(isFirstRun: true, replacedKeys: Self.replaced) == .startCard)
        let run = LaunchRun()
        let launch = run.start(setup)
        await until { run.gated }
        run.ask()
        await until { setup.classic != nil }
        let provider = SetupCardPageProvider(setup: setup, agents: nil, environment: Self.quiet)
        defer { provider.stop() }
        #expect(provider.state["classic"]?.objectValue?["workspaces"] == .number(0))
        _ = try await provider.call("cmux.setup.run", params: ["action": ["kind": .string("declineClassic")]], context: click(1))
        #expect(await launch.value == .declined && run.dialogs == 0)
    }

    /// An import that returns having made nothing (every workspace failed without throwing) is not Imported.
    @Test func anImportThatMadeNothingIsNotImported() async throws {
        let setup = FirstRunSetup(defaults: try defaults())
        #expect(setup.begin(isFirstRun: true, replacedKeys: Self.replaced))
        let provider = SetupCardPageProvider(setup: setup, agents: nil, environment: Self.quiet)
        defer { provider.stop() }
        let run = LaunchRun()
        run.madeNothing = true
        let launch = run.start(setup)
        await until { run.gated }
        run.ask()
        await until { setup.classic != nil }
        _ = try await provider.call("cmux.setup.run", params: ["action": ["kind": .string("importClassic")]], context: click(1))
        #expect(await launch.value == .accepted)
        #expect(setup.classicImported == false && provider.state["classic"]?.objectValue?["answered"] == .string("failed"))
    }

    /// A browser-only import still says what Import also does (it loads the saved pages).
    @Test func aBrowserOnlyImportSaysItLoadsPages() {
        #expect(FirstRunSetup.ClassicOffer(workspaces: 1, app: "cmux", savedAt: 0, running: false, browserTabs: 2).resumes)
        #expect(!FirstRunSetup.ClassicOffer(workspaces: 1, app: "cmux", savedAt: 0, running: false).resumes)
    }

    /// A Classic user whose other rows are all done: the launch's route makes the card wait for the migration before
    /// any card is drawn, so a card's first snapshot cannot end it before the cmux Classic row asks.
    @Test func theRouteMakesTheCardWaitForTheMigrationBeforeItIsDrawn() async throws {
        let setup = FirstRunSetup(defaults: try defaults())
        #expect(setup.route(isFirstRun: true, replacedKeys: Self.replaced) == .startCard)
        #expect(setup.awaitsClassic)
        let agent = OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude", auth: .signedIn)
        let provider = SetupCardPageProvider(setup: setup, agents: MockAgentSignInSource(agents: [agent]), environment: Self.quiet)
        defer { provider.stop() }
        await until { provider.agents.loaded && provider.state["cli"] == .string("installed") }
        #expect(!provider.allDone && setup.shows, "drawn before the migration asked: it waits")
        setup.classicSettled()
        #expect(provider.allDone, "no migration at launch: every row done")
    }

    /// A test's answer (`classicMigrationConfirmation`) wins over the card's row.
    @Test func aTestsAnswerWinsOverTheCard() async throws {
        let setup = FirstRunSetup(defaults: try defaults())
        #expect(setup.begin(isFirstRun: true, replacedKeys: Self.replaced))
        let run = LaunchRun()
        let launch = run.start(setup, seam: { _ in .accepted })
        await until { run.gated }
        run.ask()
        #expect(await launch.value == .accepted && setup.classic == nil && run.dialogs == 0)
    }

    private func until(_ done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        // test-only: waits for the provider's one async read, bounded by the deadline
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// `--skip-onboarding` or `CMUX_NEXT_SKIP_ONBOARDING=1` (UI tests, captures): no card, even one still
    /// pending from an earlier launch, and the pending state survives for the next launch that does not skip.
    @Test func skippingOnboardingHidesAPendingCardWithoutEndingIt() throws {
        let defaults = try defaults()
        #expect(!FirstRunSetup(defaults: defaults, skipsOnboarding: true).begin(isFirstRun: true, replacedKeys: Self.replaced))
        #expect(defaults.string(forKey: FirstRunSetup.stateKey) == nil, "a skipped launch starts nothing")
        #expect(FirstRunSetup(defaults: defaults).begin(isFirstRun: true, replacedKeys: Self.replaced))

        let skipped = FirstRunSetup(defaults: defaults, skipsOnboarding: true)
        #expect(!skipped.shows)
        #expect(defaults.string(forKey: FirstRunSetup.stateKey) == "pending")
        #expect(FirstRunSetup(defaults: defaults).shows, "the next launch that does not skip shows it again")
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
    var installs = 0
    var cliAfter = "missing"
    var installRuns: CheckedContinuation<Void, Never>?
}

/// Claude Code and Codex missing; an install holds until the test resumes it, then reads as installed.
@MainActor private final class HeldInstallSource: AgentSignInSource {
    var agents = [OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude", auth: .unknown, installed: false),
                  OnboardingAgent(id: "codex", name: "Codex", brand: "codex", auth: .unknown, installed: false)]
    var running: CheckedContinuation<Void, Never>?
    private(set) var installsRun: [String] = []
    private(set) var signIns: [String] = []

    func agentSignIns(recheck: Bool) async -> [OnboardingAgent] { agents }
    func signInAgent(_ id: String) async -> Bool { signIns.append(id); return true }
    func installAgent(_ id: String) async -> String? {
        installsRun.append(id)
        await withCheckedContinuation { running = $0 }
        agents = agents.map { $0.id == id ? OnboardingAgent(id: id, name: $0.name, brand: $0.brand, auth: .signedOut) : $0 }
        return nil
    }
    func agentIcon(_ agent: OnboardingAgent, side: CGFloat) -> NSImage? { nil }
}
