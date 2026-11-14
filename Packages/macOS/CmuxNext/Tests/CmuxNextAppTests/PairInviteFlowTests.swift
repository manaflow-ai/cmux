import AppKit
import Foundation
@testable import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextServer
@testable import CmuxNextPages
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
        let calls: [(String, JSONValue)] = [(PairInviteCardProvider.copyOp, ["target": "code"]), (PairInviteCardProvider.newCodeOp, [:]),
                                            (PairInviteCardProvider.setRunChiefOp, ["on": true])]
        for (op, params) in calls {
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

    /// A paired machine's result belongs to its own invite: closing the card or a New Code never
    /// shows the next machine as already added, and the next one still gets Confirm.
    @Test(arguments: [false, true]) func aPairingsResultNeverGreetsTheNextInvite(newCode: Bool) async {
        let fake = Fake()
        let source = MockServerSource()
        let provider = fake.provider(source)
        await provider.mintInvite()
        fake.push(.arrived(code: MockServerScenario.offerCode))
        await settle()
        provider.confirm(name: "build box")
        fake.push(.paired(host: "h_1"))
        await settle()
        #expect(provider.approver.lastApproved == "build box")
        if !newCode { provider.closed() }
        await provider.mintInvite()
        await settle()
        #expect(provider.approver.lastApproved == nil, "the last pairing's result is gone")
        #expect(provider.approver.lastReject == nil)
        #expect(provider.status()["approver"]?["lastApproved"] == nil)
    }

    /// SECURITY: Confirm from a key, a script or the page's own call approves nothing: only the
    /// person's own click on the panel's native Confirm (WebCardPanel's PersonControl) reaches the approve.
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
            await #expect(throws: PageError.self, "the page has no approve op: Confirm is the panel's native button") {
                _ = try await provider.call("cmux.pairInvite.confirm", params: ["name": "x"], context: context)
            }
        }
        #expect(approvals(source).isEmpty, "no page call approves")
        #expect(provider.personControl?.title == PairInviteCardStrings.confirm, "the native Confirm shows for the arrived machine")
        _ = try? await provider.call(PairInviteCardProvider.setNameOp, params: ["name": "build box"], context: PageCallContext(page: "cmux.server-cards"))
        provider.personPressed()
        #expect(approvals(source).count == 1, "the person's click on the native Confirm approves")
        let descriptor = ActionCatalog.all.first { $0.id == "server.pairAnotherMachine" }
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

    @Test func anEndedOrUsedInviteCopiesNothing() async {
        for end in [PairInviteFrame.arrived(code: MockServerScenario.offerCode), .expired, .lost, .voided(reason: "second_redemption")] {
            let fake = Fake()
            let provider = fake.provider()
            await provider.mintInvite()
            fake.push(end)
            await settle()
            await #expect(throws: PageError.self, "\(end)") {
                _ = try await provider.call(PairInviteCardProvider.copyOp, params: ["target": "code"], context: Self.gesture)
            }
            #expect(fake.copied.isEmpty, "\(end): the stale code stays off the clipboard")
        }
    }

    @Test func aSubscriptionReadsTheCurrentStateAtOnce() async throws {
        let fake = Fake()
        let provider = fake.provider()
        await provider.mintInvite()
        var events = 0
        let subscription = try await provider.subscribe(PairInviteCardProvider.changesStream, filter: [:],
                                                        context: PageCallContext(page: "cmux.server-cards")) { _ in events += 1 }
        #expect(events == 1, "a page that subscribed after the mint still reads it")
        subscription.cancel()
    }

    /// A test card that counts its sessions.
    @MainActor final class CountingCard: WebCard {
        let card: String
        var prefix: String { "cmux.test\(card)." }
        weak var host: WebCardPanel?
        var opens = 0
        var closes = 0
        var presses = 0
        init(_ card: String) { self.card = card }
        func opened(again: Bool) { if !again { opens += 1 } }
        func closed() { closes += 1 }
        func personPressed() { presses += 1 }
        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue { .null }
        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription { PageSubscription {} }
    }

    @Test func aCardClosedBeforeItsFirstSizeEndsItsSession() throws {
        let first = CountingCard("a"), second = CountingCard("b")
        let panel = try #require(WebCardPanel(descriptor: .serverCards, cards: [first, second]))
        panel.present(card: "a", over: nil, takeKeys: false)
        #expect(!panel.isVisible, "a first opening waits for the page's size")
        panel.present(card: "b", over: nil, takeKeys: false)
        #expect(first.closes == 1, "another card opening ends the waiting one's session")
        panel.dismiss()
        #expect(second.closes == 1, "a dismiss before the first size ends the session too")
    }

    @Test func stoppingServingClosesTheOpenInviteCard() throws {
        let invite = CountingCard(PairInviteCardProvider.route)
        let panel = try #require(WebCardPanel(descriptor: .serverCards, cards: [invite]))
        var made = 0
        let menu = ServerMenuBarController(makeCards: { _ in made += 1; return panel })
        menu.openInvite()
        #expect(invite.opens == 1)
        menu.hide()
        #expect(invite.closes == 1, "server.stopServing ends the invite's session (its socket)")
        #expect(!panel.isVisible)
        menu.openInvite()
        #expect(made == 2, "a later opening makes a new card panel")
    }

    @Test func stoppingServingForgetsTheFoundServer() async throws {
        let source = MockServerSource()
        var served: [any WebCard] = []
        let menu = ServerMenuBarController(makeSource: { source }, makeCards: { cards in
            served = cards
            return WebCardPanel(descriptor: .serverCards, cards: cards)
        })
        menu.openAddServer(code: MockServerScenario.offerCode)
        await settle()
        let model = try #require(served.first as? ServerPageProvider).model
        guard case .review = model.addServerStep else { Issue.record("the code finds the server: \(model.addServerStep)"); return }
        menu.hide()
        menu.openAddServer()
        await settle()
        guard case .enterCode = model.addServerStep else {
            Issue.record("a server found before Stop Serving never shows after it (its code may have expired): \(model.addServerStep)")
            return
        }
    }

    /// A panel showing `card` with an enabled native control in its footer, and a stand-in for the
    /// person's mouse (its events are the person's unless `person` is false).
    @MainActor final class Mouse {
        let panel: WebCardPanel
        private var number = 0
        private var genuine: Set<Int> = []
        private var current: NSEvent?

        init(_ card: CountingCard) throws {
            _ = NSApplication.shared
            panel = try #require(WebCardPanel(descriptor: .serverCards, cards: [card]))
            panel.present(card: card.card, over: nil, takeKeys: false)
            panel.setPersonControl(PersonControl(title: "Confirm", isEnabled: true), card: card.card)
            panel.pageResized(card: card.card, width: 460, height: 200)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.isPersonEvent = { [unowned self] in genuine.contains($0.eventNumber) }
            panel.personClick.eventInHand = { [unowned self] in current }
            panel.isKeyForPerson = { _ in true }
            // The host's own setting never decides a test: the default interval.
            panel.doubleClickInterval = { 0.5 }
        }

        /// The center of the native control, in the panel's window coordinates.
        var onControl: NSPoint {
            panel.personButton.convert(NSPoint(x: panel.personButton.bounds.midX, y: panel.personButton.bounds.midY), to: nil)
        }

        /// A click at `point` `after` seconds from now; the mouse-up comes inside the mouse-down's
        /// dispatch (a button's tracking loop) when `nested`, else as its own dispatch.
        func click(at point: NSPoint, after: TimeInterval, nested: Bool, person: Bool = true) throws {
            let time = ProcessInfo.processInfo.systemUptime + after
            let down = try event(.leftMouseDown, point, time), up = try event(.leftMouseUp, point, time + 0.05)
            genuine.insert(down.eventNumber)
            if person { genuine.insert(up.eventNumber) }
            current = down
            panel.dispatch(down) { if nested { current = up } }
            if !nested {
                current = up
                panel.dispatch(up) {}
            }
        }

        private func event(_ type: NSEvent.EventType, _ point: NSPoint, _ time: TimeInterval) throws -> NSEvent {
            number += 1
            return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                                                   windowNumber: panel.windowNumber, context: nil, eventNumber: number,
                                                   clickCount: 1, pressure: 1))
        }
    }

    @Test(arguments: [false, true]) func theNativeControlTakesOnlyThePersonsClickOnIt(nested: Bool) throws {
        let card = CountingCard(PairInviteCardProvider.route)
        let mouse = try Mouse(card)
        let panel = mouse.panel
        #expect(!panel.personButton.isHidden, "the native Confirm shows in the panel's footer")
        #expect(panel.personButton.title == "Confirm")
        try mouse.click(at: mouse.onControl, after: 1, nested: nested)
        #expect(card.presses == 1, "the person's click on Confirm, its mouse-up nested or on its own")
        try mouse.click(at: NSPoint(x: 10, y: 10), after: 2, nested: nested)
        #expect(card.presses == 1, "a click elsewhere on the card")
        try mouse.click(at: mouse.onControl, after: 3, nested: nested, person: false)
        #expect(card.presses == 1, "a posted or scripted mouse-up")
        panel.isKeyForPerson = { _ in false }
        try mouse.click(at: mouse.onControl, after: 4, nested: nested)
        #expect(card.presses == 1, "a panel that is not key")
        panel.isKeyForPerson = { _ in true }
        panel.setPersonControl(PersonControl(title: "Confirm", isEnabled: false), card: card.card)
        try mouse.click(at: mouse.onControl, after: 5, nested: nested)
        #expect(card.presses == 1, "a disabled Confirm")
        panel.setPersonControl(nil, card: card.card)
        #expect(panel.personButton.isHidden)
    }

    @Test func shrinkingAndMovingThePanelRefusesAClickAtOnce() throws {
        let card = CountingCard(PairInviteCardProvider.route)
        let mouse = try Mouse(card)
        let panel = mouse.panel
        // Confirm has stayed put a long time; then the page asks for a shorter card (Confirm moves on
        // screen with the panel), and the panel moves.
        panel.rearm(at: 0)
        panel.pageResized(card: card.card, width: 460, height: 100)
        panel.setFrame(NSRect(x: panel.frame.minX + 40, y: panel.frame.minY + 80, width: panel.frame.width,
                              height: 100 + WebCardSurface.inset * 2 + panel.personButton.fittingSize.height), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        try mouse.click(at: mouse.onControl, after: 0.05, nested: false)
        #expect(card.presses == 0, "a click right after Confirm moved on screen is not aimed at it")
        try mouse.click(at: mouse.onControl, after: 1.2, nested: false)
        #expect(card.presses == 1, "once it has stayed put, the person's click counts")
    }

    @Test func aLongerDoubleClickIntervalHoldsTheControlLonger() throws {
        let card = CountingCard(PairInviteCardProvider.route)
        let mouse = try Mouse(card)
        mouse.panel.doubleClickInterval = { 1.2 }
        mouse.panel.rearm()
        try mouse.click(at: mouse.onControl, after: 0.6, nested: false)
        #expect(card.presses == 0, "a click within the person's longer double-click interval is not taken")
        try mouse.click(at: mouse.onControl, after: 2.0, nested: false)
        #expect(card.presses == 1, "past the interval (and past the click before) it counts")
    }

    @Test func aOneByOneCardKeepsTheFooterAtFullSize() throws {
        let card = CountingCard(PairInviteCardProvider.route)
        let mouse = try Mouse(card)
        let panel = mouse.panel
        // The page asks for a 1x1 card.
        panel.pageResized(card: card.card, width: 1, height: 1)
        panel.contentView?.layoutSubtreeIfNeeded()
        let bounds = try #require(panel.contentView?.bounds)
        let button = panel.personButton
        let frame = button.convert(button.bounds, to: panel.contentView)
        #expect(frame.size == button.fittingSize, "Confirm keeps its full size")
        #expect(bounds.contains(frame), "and shows whole inside the card")
        #expect(bounds.height >= button.fittingSize.height + 2 * WebCardSurface.inset, "the footer keeps its height")
        #expect(bounds.width == button.fittingSize.width + 2 * WebCardSurface.inset, "the page's 1x1 ask took effect, clamped to the footer")
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
