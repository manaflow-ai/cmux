import Foundation
@testable import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextServer
import CmuxNextPages
import CmuxNextSettings
import Testing

/// "Pair Another Machine…" (the invite, the reverse of Add Server): the 10-symbol invite code never
/// reads as an 8-symbol server code, the wire's reply and frames decode, and the card's provider
/// relays pending, arrived (Add Server's own preview), paired, voided, expired and lost from a fake
/// socket, event driven, with the socket stopped at each end and on close.
@MainActor @Suite(.serialized) struct PairInviteFlowTests {
    // MARK: - The invite code

    @Test func anInviteCodeIsTenSymbolsShownFiveDashFive() {
        #expect(PairingCode.Invite.display("ABCDE12345") == "ABCDE-12345")
        #expect(PairingCode.Invite.display("ABCD1234") == "ABCD1234", "another length is returned unchanged")
        #expect(PairingCode.Invite.normalize(" abcde-1234o ") == "ABCDE12340", "case, dashes, spaces and O read as the server code's")
        #expect(PairingCode.Invite.normalize("il1LI-OoO00") == "1111100000")
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

    // MARK: - The card's provider (the page derives steps, buttons and the countdown: server-cards/pairInvite/model.test.ts)

    /// A fake Worker: the mint answers `mintResult`, and each watch is a socket the test pushes frames into.
    nonisolated final class Fake: @unchecked Sendable {
        var mints = 0
        var watches: [PairInvite] = []
        var socket: AsyncStream<PairInviteFrame>.Continuation?
        var socketClosed = false
        var copied: [String] = []
        var mintResult: Result<PairInvite, PairInviteFailure>?
        var invite = PairInvite(code: "ABCDE12345", expiresAt: Date().addingTimeInterval(600), watchSecret: "w1")

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

        @MainActor func provider(_ source: MockServerSource = MockServerSource()) -> PairInviteCardProvider {
            let approver = ServerModel(source: source)
            approver.start()
            return PairInviteCardProvider(service: service(), approver: approver, copy: { [self] in copied.append($0) },
                                          qr: { "data:image/png;base64,\($0.count)" })
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

    private static let gesture = PageCallContext(page: "cmux.server-cards", userGesture: true, gestureEvent: 1)

    @Test func aMintShowsTheCodeAndOpensOneSocketWithoutItsSecret() async throws {
        let fake = Fake()
        let provider = fake.provider()
        #expect(provider.mint == .idle)
        await provider.mintInvite()
        #expect(fake.mints == 1)
        #expect(fake.watches == [fake.invite], "one socket, for the minted invite")
        #expect(provider.isWatching)
        let status = provider.status()
        #expect(status["mint"]?.stringValue == "ready")
        #expect(status["invite"]?["code"]?.stringValue == "ABCDE-12345")
        #expect(status["invite"]?["line"]?.stringValue == "cmux pair ABCDE-12345")
        #expect(status["invite"]?["qr"]?.stringValue != nil)
        #expect(!status.compactText.contains("w1"), "the watch secret never reaches the page")
        fake.push(.pending(expiresAt: fake.invite.expiresAt))
        await settle()
        #expect(provider.frames.isEmpty, "pending changes nothing")
        for target in ["line", "code", "installLine"] {
            _ = try await provider.call(PairInviteCardProvider.copyOp, params: ["target": .string(target)], context: Self.gesture)
        }
        #expect(fake.copied == ["cmux pair ABCDE-12345", "ABCDE-12345", fake.invite.installLine])
    }

    @Test func copyNewCodeAndTheChiefOptionNeedThePersonsGesture() async {
        let fake = Fake()
        let provider = fake.provider()
        await provider.mintInvite()
        let script = PageCallContext(page: "cmux.server-cards")
        for (op, params) in [(PairInviteCardProvider.copyOp, ["target": "code"] as JSONValue),
                             (PairInviteCardProvider.newCodeOp, [:]), (PairInviteCardProvider.setRunChiefOp, ["on": true])] {
            await #expect(throws: PageError.self) { _ = try await provider.call(op, params: params, context: script) }
        }
        #expect(fake.copied.isEmpty)
        #expect(fake.mints == 1)
    }

    @Test func arrivedRunsAddServersPreviewThenConfirmApprovesAndPairs() async {
        let fake = Fake()
        let source = MockServerSource()
        let provider = fake.provider(source)
        await provider.mintInvite()
        fake.push(.arrived(code: MockServerScenario.offerCode))
        await settle()
        #expect(source.received.map(\.kind) == [.lookupCode(MockServerScenario.offerCode)], "Add Server's own preview")
        #expect(provider.status()["approver"]?["step"]?.stringValue == "review")
        #expect(provider.status()["approver"]?["candidate"]?["name"]?.stringValue == MockServerScenario.candidate.name)
        fake.push(.arrived(code: MockServerScenario.offerCode))
        await settle()
        #expect(source.received.count == 1, "the same arrival previews once")
        provider.confirm(name: "  build box  ")
        #expect(approvals(source) == [.approveCode(code: MockServerScenario.offerCode, team: "team_personal", name: "build box",
                                                   placeChief: MockServerScenario.candidate.isChiefBrain)],
                "Add Server's own approve, with the name typed")
        fake.push(.paired(host: "h_1"))
        await settle()
        #expect(!provider.isWatching)
        #expect(fake.socketClosed, "the socket closes once the machine is paired")
    }

    /// SECURITY: Confirm from a key, a script or the page's own call approves nothing: only the
    /// person's own click on the card (WebCardPanel.isPersonClick) reaches the approve.
    @Test func confirmIsRefusedWithoutThePersonsClick() async {
        let fake = Fake()
        let source = MockServerSource()
        let provider = fake.provider(source)
        await provider.mintInvite()
        provider.confirm(name: nil)
        #expect(approvals(source).isEmpty, "nothing to confirm before a machine arrives")
        fake.push(.arrived(code: MockServerScenario.offerCode))
        await settle()
        for context in [PageCallContext(page: "cmux.server-cards"), Self.gesture] {
            await #expect(throws: PageError.self) {
                _ = try await provider.call(PairInviteCardProvider.confirmOp, params: ["name": "x"], context: context)
            }
        }
        #expect(approvals(source).isEmpty, "a key's gesture with no click on a card approves nothing")
        let descriptor = ServerActionCatalog.descriptors().first { $0.id == "server.pairAnotherMachine" }
        #expect(descriptor?.isPersonOnly == true, "only a person may open the card and mint an invite")
        #expect(descriptor?.arguments.isEmpty == true, "the action takes no code, words or confirm: nothing to script")
    }

    @Test func aSecondMachineVoidsTheInviteAndDropsTheArrivedMachine() async {
        let fake = Fake()
        let source = MockServerSource()
        let provider = fake.provider(source)
        await provider.mintInvite()
        fake.push(.arrived(code: MockServerScenario.offerCode))
        await settle()
        fake.push(.voided(reason: "second_redemption"))
        await settle()
        #expect(!provider.isWatching)
        #expect(provider.approver.candidate == nil)
        provider.confirm(name: nil)
        #expect(approvals(source).isEmpty)
        #expect(provider.frames.map { if case .voided = $0 { "voided" } else { "other" } }.last == "voided")
        fake.push(.arrived(code: "ZZZZZZZZ"))
        await settle()
        #expect(source.received.count == 1, "a frame after the invite ended previews nothing")
    }

    @Test func anExpiryAfterTheMachineArrivedStillLetsThePersonConfirm() async {
        let fake = Fake()
        let source = MockServerSource()
        let provider = fake.provider(source)
        await provider.mintInvite()
        fake.push(.arrived(code: MockServerScenario.offerCode))
        await settle()
        fake.push(.expired)
        await settle()
        #expect(!provider.isWatching)
        provider.confirm(name: nil)
        #expect(approvals(source).count == 1, "the machine's own pairing outlives the invite")
    }

    @Test func aLostSocketSaysSoAndNeverReconnectsOnItsOwn() async {
        let fake = Fake()
        let provider = fake.provider()
        await provider.mintInvite()
        fake.socket?.finish()
        await settle()
        #expect(provider.status()["frames"]?.arrayValue?.last?["t"]?.stringValue == "lost")
        #expect(fake.watches.count == 1, "no reconnect loop")
        #expect(!provider.isWatching)
    }

    @Test func aRefusedMintSaysWhy() async {
        let fake = Fake()
        fake.mintResult = .failure(.signedOut)
        let provider = fake.provider()
        await provider.mintInvite()
        #expect(provider.status()["failure"]?["signedOut"]?.boolValue == true)
        #expect(fake.watches.isEmpty)
        fake.mintResult = .failure(.refused("Could not make a pairing code: rate limited"))
        await provider.mintInvite()
        #expect(provider.status()["failure"]?["text"]?.stringValue == "Could not make a pairing code: rate limited")
        fake.mintResult = .success(PairInvite(code: "ABCDE12345", expiresAt: Date().addingTimeInterval(-1), watchSecret: "w"))
        await provider.mintInvite()
        #expect(fake.watches.isEmpty, "an invite already out of time opens no socket")
    }

    @Test func closeStopsTheSocketAndDropsALateFrame() async {
        let fake = Fake()
        let source = MockServerSource()
        let provider = fake.provider(source)
        provider.opened(again: false)
        await settle()
        #expect(fake.mints == 1)
        provider.opened(again: true)
        await settle()
        #expect(fake.mints == 1, "a card already showing a live invite keeps it")
        let socket = fake.socket
        provider.closed()
        await settle()
        #expect(provider.mint == .idle)
        #expect(!provider.isWatching)
        #expect(fake.socketClosed)
        socket?.yield(.arrived(code: MockServerScenario.offerCode))
        await settle()
        #expect(source.received.isEmpty, "a frame after close previews nothing")
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

    @Test func withNoJoinOfferedAddDeviceIsUnchanged() async {
        let devices = AddDeviceFlowTests.Fake()
        var services = devices.services()
        services.pairAnotherMachine = { {} }
        let model = AddDeviceModel(services: services)
        await model.begin()
        #expect(!model.offersInvite)
        #expect(model.ways == [.network, .code, .newDevice], "no fourth way appears")
    }
}
