import CmuxNextCompat
import CmuxNextMacScreen
@testable import CmuxNextServer
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

/// On a Mac joined to a team, acpmux refuses every Computer Use call with `consent_required` until
/// Screen sharing and Control are on (Settings > Devices). Before, turning Computer Use on never said
/// so: cmux Remote's grants were on and every call still failed (seen 2026-11-04 on a tagged dev
/// build). The setup now asks for it, through the switches' own person path.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ComputerUseTeamConsentTests {
    typealias Fake = JoinConsentTests.Fake

    @Test func aJoinedMacWithConsentOffBlocksComputerUseUntilBothAreOn() async {
        let fake = Fake()
        let model = JoinConsentModel(services: fake.services())
        #expect(!model.computerUseBlocked, "an unread record is not reported as blocked")
        await model.refresh()
        #expect(model.computerUseBlocked)
        await model.allowComputerUse()
        #expect(fake.confirms == ["screen", "control"], "each switch asks the owner, as in Settings")
        #expect(fake.writes == ["screen true", "control true"])
        #expect(!model.computerUseBlocked)
    }

    @Test func onlyTheSwitchThatIsOffIsAsked() async {
        let fake = Fake()
        fake.record.screen = true
        let model = JoinConsentModel(services: fake.services())
        await model.refresh()
        #expect(model.computerUseBlocked)
        await model.allowComputerUse()
        #expect(fake.writes == ["control true"])
        #expect(!model.computerUseBlocked)
    }

    @Test func aCancelledConfirmTurnsNothingOnAndStops() async {
        let fake = Fake()
        fake.confirm = .cancelled
        let model = JoinConsentModel(services: fake.services())
        await model.refresh()
        await model.allowComputerUse()
        #expect(fake.confirms == ["screen"], "it stops at the first refusal")
        #expect(fake.writes.isEmpty)
        #expect(model.computerUseBlocked)
    }

    @Test func aLineThatIsNotThePersonTurnsNothingOn() async {
        let fake = Fake()
        fake.person = false
        let model = JoinConsentModel(services: fake.services())
        await model.refresh()
        await model.allowComputerUse()
        #expect(model.computerUseBlocked)
        #expect(fake.record.screen == false && fake.record.control == false)
    }

    @Test func anUnjoinedMacOrLabsOffIsNotBlocked() async {
        let fake = Fake()
        fake.status = JoinStatus(credentialPresent: false)
        let model = JoinConsentModel(services: fake.services())
        await model.refresh()
        #expect(!model.computerUseBlocked)
        fake.status = JoinStatus(credentialPresent: true, machineId: "m_1")
        fake.enabled = false
        await model.refresh()
        #expect(!model.computerUseBlocked)
    }

    // MARK: The setup card

    @Test func grantsOnButTeamConsentOffIsTheTeamStep() {
        typealias Flow = ComputerUseRemoteSetupFlow
        let both = ComputerUseRemoteSetupState.granted(accessibility: true, screenRecording: true)
        #expect(Flow.step(both, continued: false, teamConsentNeeded: true) == .team)
        #expect(Flow.step(both, continued: false, teamConsentNeeded: false) == .ready)
        // The grants come first: the team step never shows while one is off.
        let off = ComputerUseRemoteSetupState.granted(accessibility: false, screenRecording: false)
        #expect(Flow.step(off, continued: false, teamConsentNeeded: true) == .ask)
        #expect(Flow.step(.inactive, continued: false, teamConsentNeeded: true) == .none)
    }

    @MainActor @Observable final class Source: ComputerUseRemoteGrantSource {
        var remoteSetupState = ComputerUseRemoteSetupState.granted(accessibility: true, screenRecording: true)
        var teamConsentNeeded = true
        private(set) var teamRequests = 0
        func requestRemoteGrant(_ grant: ComputerUseRemoteGrant) {}
        func openRemoteGrantSettings(_ grant: ComputerUseRemoteGrant) {}
        var team: ComputerUseTeamConsent {
            ComputerUseTeamConsent(needed: { [unowned self] in teamConsentNeeded }, request: { [unowned self] in teamRequests += 1 })
        }
    }

    @MainActor @Observable final class Cards: ComputerUseRemoteSetupPresenting {
        private(set) var shown: ComputerUseRemoteSetupCard?
        @ObservationIgnored private var answer: (@MainActor (String) -> Void)?
        func showSetup(_ card: ComputerUseRemoteSetupCard, answered: @escaping @MainActor (String) -> Void) {
            shown = card
            answer = answered
        }
        func withdrawSetup() {
            shown = nil
            answer = nil
        }
        func press(_ button: String) { answer?(button) }
    }

    /// Turn On asks once per press and the card stays until the consent reads on, then ready.
    @Test func turnOnAsksAndTheCardClosesOnceTheConsentIsOn() async {
        let source = Source(), cards = Cards()
        let flow = ComputerUseRemoteSetupFlow(source: source, presenter: cards, team: source.team)
        flow.start()
        #expect(flow.step == .team)
        #expect(cards.shown == .teamConsent)
        #expect(source.teamRequests == 0, "nothing turns on before the person's press")
        cards.press(ComputerUseRemoteSetupCard.turnOnTeamButton)
        #expect(source.teamRequests == 1)
        #expect(cards.shown == .teamConsent, "a cancelled Touch ID can be retried from the same card")
        source.teamConsentNeeded = false
        for await step in ObservationStream({ flow.step }) where step == .ready { break }
        #expect(cards.shown == nil)
    }

    /// Turning a switch off in Settings after setup finished is the person's revoke: no card for it.
    @Test func aRevokeAfterSetupFinishedShowsNoCard() async {
        let source = Source(), cards = Cards()
        let flow = ComputerUseRemoteSetupFlow(source: source, presenter: cards, team: source.team)
        flow.start()
        #expect(cards.shown == .teamConsent)
        // The person turns the consent on: setup reaches ready.
        source.teamConsentNeeded = false
        for await step in ObservationStream({ flow.step }) where step == .ready { break }
        #expect(cards.shown == nil)
        // Later they turn a switch off in Settings > Devices.
        source.teamConsentNeeded = true
        for await step in ObservationStream({ flow.step }) where step == .team { break }
        #expect(cards.shown == nil, "the person's own revoke brings no card back")
        #expect(source.teamRequests == 0)
    }

    @Test func notNowClosesTheTeamCardAndTurnsNothingOn() async {
        let source = Source(), cards = Cards()
        let flow = ComputerUseRemoteSetupFlow(source: source, presenter: cards, team: source.team)
        flow.start()
        cards.press(ComputerUseRemoteSetupCard.notNowButton)
        #expect(cards.shown == nil)
        #expect(source.teamRequests == 0)
    }

    /// The card says the switches let the team's machines in too, and only the person answers it.
    @Test func theTeamCardSaysWhatTheSwitchesAllow() {
        let spec = ComputerUseApprovalCards.setupSpec(.teamConsent)
        let text = ([spec.title] + spec.lines).joined(separator: "\n")
        #expect(text.contains("Screen sharing") && text.contains("Control"))
        #expect(text.contains("your team's machines see and control this Mac"))
        #expect(spec.identifier == ComputerUseApprovalService.remoteSetupDialogIdentifier)
        #expect(spec.buttons.map(\.id) == [ComputerUseRemoteSetupCard.notNowButton, ComputerUseRemoteSetupCard.turnOnTeamButton])
    }

    /// The app's wiring: the flow follows the join consent model and its Turn On writes through it.
    @Test func theAppsTeamConsentFollowsTheJoinConsentModel() async {
        let fake = Fake()
        let model = JoinConsentModel(services: fake.services())
        let team = model.computerUseTeamConsent
        #expect(!team.needed())
        await model.refresh()
        #expect(team.needed())
        team.request()
        for await blocked in ObservationStream({ model.computerUseBlocked }) where !blocked { break }
        #expect(fake.writes == ["screen true", "control true"])
        #expect(!team.needed())
    }
}
