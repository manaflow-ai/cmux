import AppKit
import Foundation
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextServer
import CmuxNextSettings
import Testing

/// "Pair Another Machine…" (the invite, the reverse of Add Server): the 10-symbol invite code never
/// reads as an 8-symbol server code, the wire's reply and frames decode, and the card's model
/// relays pending, arrived (Add Server's own preview), paired, voided, expired and lost from a fake
/// socket, event driven, with the socket stopped at each end and on close. The card is native
/// (``PairInviteDialog``): only the person's own click on its Confirm pairs.
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
        #expect(invite.installLine == AddDevicePlatform.pinnedInstall(then: "~/.cmux/bin/cmux pair ABCDE-12345"))
        #expect(invite.installLine.contains("install-static/\(AddDevicePlatform.installStaticSHA256).sh"))
        #expect(!invite.installLine.contains("| sh"), "the invite pins the script, never curl | sh")
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

    // MARK: - The card's model and its native card

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

        @MainActor func provider(_ source: MockServerSource = MockServerSource()) -> PairInviteModel {
            let approver = ServerModel(source: source)
            approver.start()
            return PairInviteModel(service: service(), approver: approver, copy: { [self] in copied.append($0) },
                                   qr: { Data($0.utf8) })
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

    private func spec(_ provider: PairInviteModel) -> CmuxDialogSpec {
        PairInviteCard.spec(provider.step(), approver: provider.approver, qr: provider.qr, copied: nil)
    }

    @Test func aMintShowsTheCodeAndOpensOneSocketWithoutItsSecret() async throws {
        let fake = Fake()
        let provider = fake.provider()
        #expect(provider.mint == .idle)
        await provider.mintInvite()
        #expect(fake.mints == 1)
        #expect(fake.watches == [fake.invite], "one socket, for the minted invite")
        #expect(provider.isWatching)
        #expect(provider.mint == .ready)
        #expect(provider.step() == .showing(fake.invite))
        let card = spec(provider)
        let code = try #require(card.fields.lazy.compactMap { if case let .pairingCode(code) = $0 { code } else { nil } }.first)
        #expect(code.code == "ABCDE-12345")
        #expect(code.image == Data(fake.invite.qrPayload.utf8), "the QR carries the invite")
        #expect(code.expiresAt == fake.invite.expiresAt, "the card counts down to the invite's expiry")
        #expect(card.fields.contains(.copyLine(id: "copyLine", label: nil, text: "cmux pair ABCDE-12345", button: PairInviteStrings.copyLine)))
        #expect(!"\(card)".contains("w1"), "the watch secret never reaches the card")
        fake.push(.pending(expiresAt: fake.invite.expiresAt))
        await settle()
        #expect(provider.frames.isEmpty, "pending changes nothing")
        for target in [PairInviteModel.CopyTarget.line, .code, .installLine] { #expect(provider.copy(target)) }
        #expect(fake.copied == ["cmux pair ABCDE-12345", "ABCDE-12345", fake.invite.installLine])
    }

    /// Every step of the card has words and a way out: never an empty glass shell, and Escape or a button always
    /// closes it (Lawrence 2026-11-17).
    @Test func everyStepHasWordsAndAWayOut() {
        let invite = PairInvite(code: "ABCDE12345", expiresAt: Date().addingTimeInterval(600), watchSecret: "w")
        let found = MockServerScenario.candidate
        let steps: [PairInviteStep] = [.minting, .showing(invite), .lookingUp(invite), .review(invite, found), .approving(invite, found),
                                       .approveFailed(invite, found, "refused"), .paired("build box"), .voided, .expired, .lost,
                                       .signedOut, .failed("rate limited")]
        let approver = ServerModel(source: MockServerSource())
        for step in steps {
            let card = PairInviteCard.spec(step, approver: approver, qr: { _ in nil }, copied: nil)
            #expect(CmuxFloatingDialogPanel.hasContent(card), "\(step): words on the first frame")
            #expect(card.cancelButton != nil, "\(step): Escape closes it")
        }
    }

    @Test func arrivedRunsAddServersPreviewThenConfirmApprovesAndPairs() async {
        let fake = Fake()
        let source = MockServerSource()
        let provider = fake.provider(source)
        await provider.mintInvite()
        fake.push(.arrived(code: MockServerScenario.offerCode))
        await settle()
        #expect(source.received.map(\.kind) == [.lookupCode(MockServerScenario.offerCode)], "Add Server's own preview")
        guard case let .review(_, found) = provider.step() else { Issue.record("Add Server's review: \(provider.step())"); return }
        #expect(found.name == MockServerScenario.candidate.name)
        fake.push(.arrived(code: MockServerScenario.offerCode))
        await settle()
        #expect(source.received.count == 1, "the same arrival previews once")
        provider.confirm(name: "  build box  ", runChief: nil)
        #expect(approvals(source) == [.approveCode(code: MockServerScenario.offerCode, team: "team_personal", name: "build box",
                                                   placeChief: MockServerScenario.candidate.isChiefBrain)],
                "Add Server's own approve, with the name typed")
        fake.push(.paired(host: "h_1"))
        await settle()
        #expect(!provider.isWatching)
        #expect(fake.socketClosed, "the socket closes once the machine is paired")
    }

    /// A paired machine's result belongs to its own invite: closing the card or a New Code never
    /// shows the next machine as already added, and the next one still gets Confirm.
    @Test(arguments: [false, true]) func aPairingsResultNeverGreetsTheNextInvite(newCode: Bool) async {
        let fake = Fake()
        let source = MockServerSource()
        let provider = fake.provider(source)
        await provider.mintInvite()
        fake.push(.arrived(code: MockServerScenario.offerCode))
        await settle()
        provider.confirm(name: "build box", runChief: nil)
        fake.push(.paired(host: "h_1"))
        await settle()
        #expect(provider.approver.lastApproved == "build box")
        if !newCode { provider.closed() }
        await provider.mintInvite()
        await settle()
        #expect(provider.approver.lastApproved == nil, "the last pairing's result is gone")
        #expect(provider.approver.lastReject == nil)
        #expect(provider.step() == .showing(fake.invite))
    }

    /// SECURITY: Confirm from Return, a press of its button (Accessibility, a script) or the card's own action approves
    /// nothing: only the person's own click, which the panel reads from its dispatch (``CmuxDialogPersonClick``),
    /// reaches the approve.
    @Test func confirmIsRefusedWithoutThePersonsClick() async throws {
        _ = NSApplication.shared
        let fake = Fake()
        let source = MockServerSource()
        let dialog = PairInviteDialog(model: fake.provider(source))
        dialog.open(over: nil)
        await settle()
        fake.push(.arrived(code: MockServerScenario.offerCode))
        await settle()
        let card = try #require(dialog.panel.dialogView)
        #expect(card.spec.title == PairInviteStrings.arrived, "the card follows the socket")
        let confirm = try #require(card.spec.buttons.first { $0.id == "confirm" })
        #expect(confirm.personOnly && confirm.isEnabled, "Confirm shows for the arrived machine, click only")
        #expect(card.spec.defaultButton == nil, "Return presses nothing")
        card.dialog.handle(.return, modifiers: [])
        card.dialog.press("confirm")
        #expect(approvals(source).isEmpty, "no key and no programmatic press approves")
        #expect(dialog.panel.personOnlyClick != nil, "the panel reads the person's own click")
        card.dialog.setValue(.text("build box"), for: "name")
        dialog.panel.onPersonPress?("confirm")
        #expect(approvals(source) == [.approveCode(code: MockServerScenario.offerCode, team: "team_personal", name: "build box",
                                                   placeChief: MockServerScenario.candidate.isChiefBrain)],
                "the person's click on Confirm approves, with the name typed")
        let descriptor = ActionCatalog.all.first { $0.id == "server.pairAnotherMachine" }
        #expect(descriptor?.isPersonOnly == true, "only a person may open the card and mint an invite")
        #expect(descriptor?.arguments.isEmpty == true, "the action takes no code, words or confirm: nothing to script")
        card.dialog.handle(.escape, modifiers: [])
        #expect(!dialog.panel.isVisible, "Escape closes it")
        #expect(!dialog.model.isWatching, "closing the card stops the socket")
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
        provider.confirm(name: nil, runChief: nil)
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
        provider.confirm(name: nil, runChief: nil)
        #expect(approvals(source).count == 1, "the machine's own pairing outlives the invite")
    }

    @Test func anEndedOrUsedInviteCopiesNothing() async {
        for end in [PairInviteFrame.arrived(code: MockServerScenario.offerCode), .expired, .lost, .voided(reason: "second_redemption")] {
            let fake = Fake()
            let provider = fake.provider()
            await provider.mintInvite()
            fake.push(end)
            await settle()
            #expect(!provider.copy(.code), "\(end)")
            #expect(fake.copied.isEmpty, "\(end): the stale code stays off the clipboard")
        }
    }

    @Test func stoppingServingClosesTheOpenInviteCard() async {
        _ = NSApplication.shared
        let fake = Fake()
        var made = 0
        let menu = ServerMenuBarController(makeInvite: { made += 1; return PairInviteDialog(model: fake.provider()) })
        menu.openInvite()
        await settle()
        #expect(fake.mints == 1)
        #expect(fake.watches.count == 1)
        menu.hide()
        #expect(fake.socketClosed, "server.stopServing ends the invite's session (its socket)")
        menu.openInvite()
        await settle()
        #expect(made == 1, "the card is made once and kept")
        #expect(fake.mints == 2, "a later opening mints a new invite")
    }

    @Test func stoppingServingForgetsTheFoundServer() async throws {
        _ = NSApplication.shared
        let source = MockServerSource()
        var made: AddServerDialog?
        let menu = ServerMenuBarController(makeSource: { source }, makeAddServer: { model in
            let card = AddServerDialog(model: model)
            made = card
            return card
        })
        menu.openAddServer(code: MockServerScenario.offerCode)
        await settle()
        let model = try #require(made).model
        guard case .review = model.addServerStep else { Issue.record("the code finds the server: \(model.addServerStep)"); return }
        menu.hide()
        menu.openAddServer()
        await settle()
        guard case .enterCode = model.addServerStep else {
            Issue.record("a server found before Stop Serving never shows after it (its code may have expired): \(model.addServerStep)")
            return
        }
    }

    @Test func aLostSocketSaysSoAndNeverReconnectsOnItsOwn() async {
        let fake = Fake()
        let provider = fake.provider()
        await provider.mintInvite()
        fake.socket?.finish()
        await settle()
        #expect(provider.step() == .lost)
        #expect(fake.watches.count == 1, "no reconnect loop")
        #expect(!provider.isWatching)
    }

    @Test func aRefusedMintSaysWhy() async {
        let fake = Fake()
        fake.mintResult = .failure(.signedOut)
        let provider = fake.provider()
        await provider.mintInvite()
        #expect(provider.step() == .signedOut)
        #expect(fake.watches.isEmpty)
        fake.mintResult = .failure(.refused("Could not make a pairing code: rate limited"))
        await provider.mintInvite()
        #expect(provider.step() == .failed("Could not make a pairing code: rate limited"))
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
