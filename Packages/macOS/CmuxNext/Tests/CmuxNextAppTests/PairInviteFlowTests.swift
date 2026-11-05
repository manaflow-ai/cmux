import Foundation
@testable import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextServer
import Testing

/// "Pair Another Machine…" (the invite, the reverse of Add Server): the 10-symbol invite code never
/// reads as an 8-symbol server code, the wire's reply and frames decode, and the card walks
/// pending, arrived (Add Server's own preview), paired, voided, expired and lost over a fake socket,
/// event driven, with the socket and countdown stopped at each end and on close.
@MainActor @Suite(.serialized) struct PairInviteFlowTests {
    // MARK: - The invite code

    @Test func anInviteCodeIsTenSymbolsShownFiveDashFive() {
        #expect(PairingCode.Invite.display("ABCDE12345") == "ABCDE-12345")
        #expect(PairingCode.Invite.display("ABCD1234") == "ABCD1234", "another length is returned unchanged")
        #expect(PairingCode.Invite.normalize(" abcde-1234o ") == "ABCDE12340", "case, dashes, spaces and O read as the server code's")
        #expect(PairingCode.Invite.normalize("il1LI-OoO00") == "11111000000")
        #expect(PairingCode.Invite.isComplete("abcde-12345"))
        #expect(PairingCode.Invite.isComplete("ABCDE 1234O"))
        #expect(!PairingCode.Invite.isComplete("ABCDE-1234"), "nine symbols")
        #expect(!PairingCode.Invite.isComplete("ABCDE-123456"), "eleven symbols")
        #expect(!PairingCode.Invite.isComplete("ABCDE-1234U"), "U is not a Crockford symbol")
    }

    @Test func anInviteCodeAndAServerCodeNeverReadAsEachOther() {
        let server = MockServerScenario.offerCode
        let invite = PairInviteService.mockCode
        #expect(PairingCode.isComplete(server))
        #expect(!PairingCode.Invite.isComplete(server), "an 8-symbol server code is no invite")
        #expect(PairingCode.Invite.isComplete(invite))
        #expect(!PairingCode.isComplete(invite), "a 10-symbol invite is no server code")
        #expect(!PairingCode.isComplete(PairingCode.Invite.display(invite)))
    }

    @Test func theLineTheInstallLineAndTheQRCarryTheCode() {
        let invite = PairInvite(code: "abcde-12345", expiresAt: Date(timeIntervalSince1970: 0), watchSecret: "s")
        #expect(invite.code == "ABCDE12345")
        #expect(invite.displayCode == "ABCDE-12345")
        #expect(invite.line == "cmux pair ABCDE-12345")
        #expect(invite.installLine == "curl -fsSL https://cmux.com/tui/install-static.sh | sh && ~/.cmux/bin/cmux pair ABCDE-12345")
        #expect(invite.qrPayload == "https://cmux.com/pair?i=ABCDE12345", "the invite rides in i=, never the server code's c=")
    }

    // MARK: - The wire

    @Test func theMintReplyDecodes() throws {
        let invite = try #require(PairInvite.decode([
            "invite": "ABCDE12345", "display": "ABCDE-12345", "expires_at": 1_790_976_600_000, "watch_secret": "w1",
        ] as [String: Any]))
        #expect(invite.code == "ABCDE12345")
        #expect(invite.expiresAt == Date(timeIntervalSince1970: 1_790_976_600), "epoch milliseconds")
        #expect(invite.watchSecret == "w1")
        let iso = PairInvite.decode(["invite": "ABCDE12345", "expires_at": "2026-10-29T03:30:00.123Z", "watch_secret": "w1"] as [String: Any])
        #expect(iso != nil, "an RFC 3339 time reads too")
        #expect(PairInvite.decode(["invite": "ABCDE12345", "expires_at": 1, "watch_secret": ""] as [String: Any]) == nil, "no secret")
        #expect(PairInvite.decode(["invite": "ABCD1234", "expires_at": 1, "watch_secret": "w"] as [String: Any]) == nil,
                "a server code is no invite")
        #expect(PairInvite.decode(["invite": "ABCDE12345", "watch_secret": "w"] as [String: Any]) == nil, "no expiry")
        #expect(PairInvite.decode(nil) == nil)
    }

    @Test func theWatchFramesDecode() {
        let frame = { (text: String) in PairInviteFrame.decode(Data(text.utf8)) }
        #expect(frame(#"{"t":"pending","expires_at":1000}"#) == .pending(expiresAt: Date(timeIntervalSince1970: 1)))
        #expect(frame(#"{"t":"arrived","code":"7kq4-m2xd","info":{"name":"build-01"},"thumbprint":"x","country":"DE","expires_at":1}"#)
            == .arrived(code: "7KQ4M2XD"))
        #expect(frame(#"{"t":"arrived","code":"ABCDE12345"}"#) == nil, "an arrived machine's code is an 8-symbol server code")
        #expect(frame(#"{"t":"paired","host":"h_1"}"#) == .paired(host: "h_1"))
        #expect(frame(#"{"t":"voided","reason":"second_redemption"}"#) == .voided(reason: "second_redemption"))
        #expect(frame(#"{"t":"later"}"#) == nil)
        #expect(frame("not json") == nil)
        #expect(PairInviteFrame.protocols(secret: "abc") == ["cmux.pair-invite.v1", "watch.abc"])
    }

    @Test func theSocketOpensOnTheWorkerAndReadsItsClose() {
        let base = URL(string: "https://api.cmux.example")!
        #expect(PairInviteService.watchURL(base, invite: "ABCDE12345").absoluteString
            == "wss://api.cmux.example/v1/pair/invite/wait?invite=ABCDE12345")
        #expect(PairInviteService.watchURL(URL(string: "http://localhost:8787")!, invite: "ABCDE12345").absoluteString
            == "ws://localhost:8787/v1/pair/invite/wait?invite=ABCDE12345")
        let invite = PairInvite(code: "ABCDE12345", expiresAt: Date(timeIntervalSince1970: 1000), watchSecret: "w")
        #expect(PairInviteService.closed(4408, invite: invite, now: Date(timeIntervalSince1970: 100)) == .expired)
        #expect(PairInviteService.closed(0, invite: invite, now: Date(timeIntervalSince1970: 995)) == .expired,
                "a close at about the expiry is the expiry, whatever code Foundation reports")
        #expect(PairInviteService.closed(1006, invite: invite, now: Date(timeIntervalSince1970: 100)) == .lost)
    }

    // MARK: - The flow

    /// A fake Worker: the mint answers `mintResult`, and each watch is a socket the test pushes frames into.
    nonisolated final class Fake: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var mints = 0
        var watches: [PairInvite] = []
        var socket: AsyncStream<PairInviteFrame>.Continuation?
        var socketClosed = false
        var copied: [String] = []
        var mintResult: Result<PairInvite, PairInviteFailure>?
        // Ten minutes after the clock's start.
        var invite = PairInvite(code: "ABCDE12345", expiresAt: Date(timeIntervalSince1970: 1_000_600), watchSecret: "w1")

        func service() -> PairInviteService {
            PairInviteService(
                mint: { [self] in mints += 1; return mintResult ?? .success(invite) },
                watch: { [self] invite in
                    watches.append(invite)
                    return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
                        socket = continuation
                        continuation.onTermination = { [self] _ in socketClosed = true }
                    }
                })
        }

        @MainActor func model(_ source: MockServerSource = MockServerSource()) -> PairInviteModel {
            let approver = ServerModel(source: source)
            approver.start()
            // The countdown's sleep waits until it is cancelled: these tests move time by hand (tick()).
            return PairInviteModel(service: service(), approver: approver, copy: { [self] in copied.append($0) },
                                   clock: { [self] in now }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        }

        func push(_ frame: PairInviteFrame) { socket?.yield(frame) }
    }

    /// Lets the socket's task, the mock server's echo and the approver's answers run.
    private func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    private func approvals(_ source: MockServerSource) -> [ServerIntentKind] {
        source.received.map(\.kind).filter { if case .approveCode = $0 { true } else { false } }
    }

    @Test func aMintShowsTheCodeAndOpensOneSocket() async {
        let fake = Fake()
        let model = fake.model()
        #expect(model.phase == .idle)
        await model.mint()
        #expect(fake.mints == 1)
        #expect(model.step == .showing(fake.invite))
        #expect(model.secondsLeft == 600)
        #expect(fake.watches == [fake.invite], "one socket, for the minted invite")
        #expect(model.isWatching)
        #expect(model.buttons.map(\.action) == [.cancel])
        fake.push(.pending(expiresAt: fake.invite.expiresAt))
        await settle()
        #expect(model.step == .showing(fake.invite), "pending changes nothing")
        model.perform(.copyLine)
        model.perform(.copyCode)
        model.perform(.copyInstallLine)
        #expect(fake.copied == ["cmux pair ABCDE-12345", "ABCDE-12345", fake.invite.installLine])
        #expect(model.copied == .installLine)
    }

    @Test func arrivedRunsAddServersPreviewThenConfirmApprovesAndPairs() async {
        let fake = Fake()
        let source = MockServerSource()
        let model = fake.model(source)
        await model.mint()
        fake.push(.arrived(code: MockServerScenario.offerCode))
        await settle()
        #expect(source.received.map(\.kind) == [.lookupCode(MockServerScenario.offerCode)], "Add Server's own preview")
        #expect(model.step == .review(fake.invite, MockServerScenario.candidate))
        #expect(model.secondsLeft == nil, "the code's countdown is gone once a machine used it")
        #expect(model.buttons.map(\.action) == [.cancel, .confirm])
        #expect(model.canConfirm)
        model.confirm(name: "  build box  ")
        #expect(approvals(source) == [.approveCode(code: MockServerScenario.offerCode, team: "team_personal", name: "build box",
                                                   placeChief: MockServerScenario.candidate.isChiefBrain)],
                "Add Server's own approve, with the name typed")
        await settle()
        #expect(model.step == .paired("build box"))
        #expect(model.buttons.map(\.action) == [.done])
        fake.push(.paired(host: "h_1"))
        await settle()
        #expect(model.phase == .paired(host: "h_1"))
        #expect(model.step == .paired("build box"))
        #expect(!model.isWatching)
        #expect(fake.socketClosed, "the socket closes once the machine is paired")
    }

    /// SECURITY: Confirm's key, its action and the card's perform approve nothing: only the panel's
    /// person-click check calls confirm() (PairInviteConfirmTests drives that check).
    @Test func confirmIsRefusedWithoutThePersonsClick() async {
        let fake = Fake()
        let source = MockServerSource()
        let model = fake.model(source)
        await model.mint()
        #expect(!model.canConfirm, "nothing to confirm before a machine arrives")
        model.confirm()
        #expect(approvals(source).isEmpty)
        fake.push(.arrived(code: MockServerScenario.offerCode))
        await settle()
        #expect(model.perform(.confirm) == false)
        #expect(model.perform(.retry) == false)
        #expect(PairInviteAction.confirm.isPersonClickOnly && PairInviteAction.retry.isPersonClickOnly)
        #expect(approvals(source).isEmpty, "perform(.confirm), the key's and Accessibility's path, approves nothing")
        let descriptor = ServerActionCatalog.descriptors().first { $0.id == "server.pairAnotherMachine" }
        #expect(descriptor?.isPersonOnly == true, "only a person may open the card and mint an invite")
        #expect(descriptor?.arguments.isEmpty == true, "the action takes no code, words or confirm: nothing to script")
    }

    @Test func aSecondMachineVoidsTheInviteAndOffersANewCode() async {
        let fake = Fake()
        let model = fake.model()
        await model.mint()
        fake.push(.voided(reason: "second_redemption"))
        await settle()
        #expect(model.step == .voided)
        #expect(!model.isWatching)
        #expect(model.buttons.map(\.action) == [.cancel, .newCode])
        // Voided after it arrived too: the arrived machine's facts go.
        let source = MockServerSource()
        let arrived = fake.model(source)
        await arrived.mint()
        fake.push(.arrived(code: MockServerScenario.offerCode))
        await settle()
        #expect(arrived.step == .review(fake.invite, MockServerScenario.candidate))
        fake.push(.voided(reason: "second_redemption"))
        await settle()
        #expect(arrived.step == .voided)
        #expect(arrived.approver.candidate == nil)
        #expect(!arrived.canConfirm)
        #expect(approvals(source).isEmpty)
        // New Code mints again.
        arrived.perform(.newCode)
        await settle()
        #expect(arrived.step == .showing(fake.invite))
    }

    @Test func theCodeExpiresAtItsTimeOrTheWorkersClose() async {
        let fake = Fake()
        let model = fake.model()
        await model.mint()
        fake.now = fake.invite.expiresAt.addingTimeInterval(-30)
        model.tick()
        #expect(model.secondsLeft == 30)
        fake.now = fake.invite.expiresAt
        model.tick()
        #expect(model.step == .expired)
        #expect(!model.isWatching)
        #expect(model.buttons.map(\.action) == [.cancel, .newCode])
        let closed = fake.model()
        fake.now = Date(timeIntervalSince1970: 1_000_000)
        await closed.mint()
        fake.push(.expired)
        await settle()
        #expect(closed.step == .expired, "the Worker's 4408")
    }

    @Test func anExpiryAfterTheMachineArrivedStillLetsThePersonConfirm() async {
        let fake = Fake()
        let source = MockServerSource()
        let model = fake.model(source)
        await model.mint()
        fake.push(.arrived(code: MockServerScenario.offerCode))
        await settle()
        fake.push(.expired)
        await settle()
        #expect(model.step == .review(fake.invite, MockServerScenario.candidate), "the machine's own pairing outlives the invite")
        #expect(model.canConfirm)
    }

    @Test func aLostSocketSaysSoAndNeverReconnectsOnItsOwn() async {
        let fake = Fake()
        let model = fake.model()
        await model.mint()
        fake.socket?.finish()
        await settle()
        #expect(model.step == .lost)
        #expect(fake.watches.count == 1, "no reconnect loop")
        #expect(model.buttons.map(\.action) == [.cancel, .newCode])
    }

    @Test func aRefusedMintSaysWhy() async {
        let fake = Fake()
        fake.mintResult = .failure(.signedOut)
        let model = fake.model()
        await model.mint()
        #expect(model.step == .signedOut)
        #expect(fake.watches.isEmpty)
        fake.mintResult = .failure(.refused("Could not make a pairing code: rate limited"))
        await model.mint()
        #expect(model.step == .failed("Could not make a pairing code: rate limited"))
        fake.mintResult = .success(PairInvite(code: "ABCDE12345", expiresAt: fake.now.addingTimeInterval(-1), watchSecret: "w"))
        await model.mint()
        #expect(model.step == .expired, "an invite that is already out of time never shows")
        #expect(fake.watches.isEmpty)
    }

    @Test func closeStopsTheSocketAndDropsALateFrame() async {
        let fake = Fake()
        let source = MockServerSource()
        let model = fake.model(source)
        await model.mint()
        let socket = fake.socket
        #expect(model.perform(.cancel), "Cancel closes the card")
        await settle()
        #expect(model.phase == .idle)
        #expect(!model.isWatching)
        #expect(fake.socketClosed)
        socket?.yield(.arrived(code: MockServerScenario.offerCode))
        await settle()
        #expect(model.phase == .idle)
        #expect(source.received.isEmpty, "a frame after close previews nothing")
    }

    @Test func theMockPreviewsTheGalleryMachine() async {
        let approver = ServerModel(source: MockServerSource())
        approver.start()
        let now = MockServerScenario.referenceDate
        let model = PairInviteModel(service: .mock(now: now, frames: [.arrived(code: MockServerScenario.offerCode)]), approver: approver,
                                    clock: { now }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        await model.mint()
        await settle()
        guard case let .review(invite, candidate) = model.step else {
            Issue.record("the mock arrives at review, got \(model.step)")
            return
        }
        #expect(invite.code == PairInviteService.mockCode)
        #expect(candidate == MockServerScenario.candidate)
        model.close()
    }

    // MARK: - Add Device

    @Test func signedInTheAnyMachineWayHandsOffToTheInvite() async {
        let devices = AddDeviceFlowTests.Fake()
        let join = MachineJoinLineFlowTests.Fake()
        var services = MachineJoinLineFlowTests.services(devices, join)
        var opened = 0
        services.pairAnotherMachine = { { opened += 1 } }
        let model = join.deviceModel(services)
        await model.begin(way: .joinLine)
        #expect(model.offersInvite)
        #expect(model.buttons.map(\.action) == [.cancel, .pairAnotherMachine])
        #expect(join.mints.isEmpty, "no ticket line is made")
        #expect(model.perform(.pairAnotherMachine), "the hand-off closes the card")
        #expect(opened == 1)
    }

    @Test func signedOutTheAnyMachineWayKeepsTheTicketLine() async {
        let devices = AddDeviceFlowTests.Fake()
        let join = MachineJoinLineFlowTests.Fake()
        var services = MachineJoinLineFlowTests.services(devices, join)
        services.pairAnotherMachine = { nil }
        let model = join.deviceModel(services)
        await model.begin(way: .joinLine)
        #expect(!model.offersInvite)
        #expect(model.buttons.map(\.action) == [.cancel, .makeJoinLine])
        #expect(model.perform(.pairAnotherMachine) == false)
    }

    @Test func withTheLabsSwitchOffAddDeviceIsUnchanged() async {
        let devices = AddDeviceFlowTests.Fake()
        var services = devices.services()
        services.pairAnotherMachine = { {} }
        let model = AddDeviceModel(services: services)
        await model.begin()
        #expect(!model.offersInvite)
        #expect(model.ways == [.network, .code, .newDevice], "no fourth way appears")
    }
}
