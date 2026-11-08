import AppKit
@testable import CmuxNextPages
@testable import CmuxNextServer
import CmuxNextSettings
import Foundation
import Testing

/// The server pages' provider (webviews/src/pages/server-cards/server): the model's state as page
/// JSON (the offer's QR image, never its key fingerprint), the Add Server draft and step, and the
/// changes only a person may make (the switch, Show Pairing Code, Fix, Revoke, the Chief option)
/// refused without their own click or key in the page. Approve is no page op at all: it is the card
/// panel's native control, and only its press (``ServerPageProvider/personPressed()``) adds a server.
@MainActor
struct ServerPageProviderTests {
    private let page = PageCallContext(page: "cmux.server-cards")
    private let person = PageCallContext(page: "cmux.server-cards", userGesture: true, gestureEvent: 1)

    private func provider(_ scenario: MockServerScenario = .unpaired) -> (MockServerSource, ServerPageProvider) {
        let source = MockServerSource(scenario: scenario)
        source.echoImmediately = false
        let model = ServerModel(source: source)
        model.start()
        return (source, ServerPageProvider(model: model, personOnlyMessage: "Only you can do this.", qr: { "data:image/png;base64,\($0.count)" }))
    }

    private func call(_ provider: ServerPageProvider, _ op: String, _ params: JSONValue = [:], as context: PageCallContext? = nil) async throws {
        _ = try await provider.call(op, params: params, context: context ?? page)
    }

    @Test func statusCarriesTheSnapshotWithItsQRImage() async throws {
        let (_, provider) = provider()
        let status = try await provider.call(ServerPageProvider.statusOp, params: [:], context: page)
        #expect(status["connection"]?["state"] == "connected")
        #expect(status["snapshot"]?["hostName"] == "Studio")
        let offer = status["snapshot"]?["pairing"]?["offer"]
        #expect(offer?["code"] == .string(MockServerScenario.offerCode))
        #expect(offer?["qr"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)
        #expect(offer?["fingerprint"] == nil)
        #expect(status["approver"]?["step"] == "enterCode")
        #expect(status["pending"]?["switching"] == false)
    }

    @Test(arguments: [
        ["kind": "setEnabled", "on": false],
        ["kind": "showPairingCode"],
        ["kind": "fixCheck", "check": "disk.low"],
        ["kind": "revokeDevice", "device": "dev_mbp"],
    ] as [JSONValue])
    func changesGoOnlyFromThePersonsOwnClickOrKey(_ params: JSONValue) async throws {
        let (source, provider) = provider(.healthyMac)
        await #expect(throws: PageError.self) { try await call(provider, ServerPageProvider.sendOp, params) }
        #expect(source.received.isEmpty)
        try await call(provider, ServerPageProvider.sendOp, params, as: person)
        #expect(source.received.count == 1)
        let status = try await provider.call(ServerPageProvider.statusOp, params: [:], context: page)
        #expect(status["pending"] != ["switching": false, "pairing": false, "fixing": [], "revoking": []])
    }

    @Test func aPageCannotSendACodeIntentThroughSend() async {
        let (source, provider) = provider()
        await #expect(throws: PageError.self) {
            try await call(provider, ServerPageProvider.sendOp, ["kind": "approveCode", "code": "7KQ4M2XD", "team": "t", "name": "n"], as: person)
        }
        #expect(source.received.isEmpty)
    }

    @Test func approveNeedsAFoundServerAndThePersonsClick() async throws {
        let (source, provider) = provider()
        try await call(provider, ServerPageProvider.setCodeOp, ["code": "7kq4m2xd"])
        #expect(source.received.map(\.kind) == [.lookupCode(MockServerScenario.offerCode)])
        // Not found yet: no native control shows, and a press sends nothing.
        #expect(provider.personControl == nil)
        provider.personPressed()
        #expect(source.received.count == 1)
        source.deliverHeld()
        var status = try await provider.call(ServerPageProvider.statusOp, params: [:], context: page)
        #expect(status["approver"]?["step"] == "review")
        #expect(status["approver"]?["candidate"]?["teams"]?.arrayValue?.count == 2)
        #expect(status["approver"]?["draft"]?["code"] == "7KQ4-M2XD")
        // SECURITY: no page call, even with the person's key, approves: Approve is the card panel's
        // native control (PersonControl), and the page has no op for it.
        #expect(provider.personControl == PersonControl(title: ServerStrings.approve, isEnabled: true))
        await #expect(throws: PageError.self) { try await call(provider, "cmux.server.approver.approve", ["name": "box"]) }
        await #expect(throws: PageError.self) { try await call(provider, "cmux.server.approver.approve", ["name": "box"], as: person) }
        #expect(source.received.count == 1)
        try await call(provider, ServerPageProvider.setTeamOp, ["team": "team_manaflow"])
        // The Name field reaches the draft by setName; the native press reads it, trimmed.
        try await call(provider, ServerPageProvider.setNameOp, ["name": " box "])
        provider.personPressed()
        #expect(source.received.last?.kind == .approveCode(code: MockServerScenario.offerCode, team: "team_manaflow", name: "box", placeChief: false))
        status = try await provider.call(ServerPageProvider.statusOp, params: [:], context: page)
        #expect(status["approver"]?["step"] == "approving")
        // While it adds, the control shows disabled and a second press sends nothing.
        #expect(provider.personControl == PersonControl(title: ServerStrings.adding, isEnabled: false))
        provider.personPressed()
        #expect(source.received.count == 2)
    }

    @Test func aTeamTheServerDoesNotOfferIsRefused() async throws {
        let (source, provider) = provider()
        try await call(provider, ServerPageProvider.setCodeOp, ["code": .string(MockServerScenario.offerCode)])
        source.deliverHeld()
        await #expect(throws: PageError.self) { try await call(provider, ServerPageProvider.setTeamOp, ["team": "team_other"]) }
        #expect(provider.model.approval.team == "team_personal")
    }

    @Test func theChiefOptionIsThePersons() async throws {
        let (_, provider) = provider()
        await #expect(throws: PageError.self) { try await call(provider, ServerPageProvider.setRunChiefOp, ["on": true]) }
        #expect(!provider.model.approval.runChief)
        try await call(provider, ServerPageProvider.setRunChiefOp, ["on": true], as: person)
        #expect(provider.model.approval.runChief)
    }

    @Test func cancelDropsTheDraft() async throws {
        let (_, provider) = provider()
        try await call(provider, ServerPageProvider.setCodeOp, ["code": "7KQ4"])
        try await call(provider, ServerPageProvider.cancelOp)
        #expect(provider.model.approval == ServerApprovalDraft())
    }

    @Test func eachOpeningIsANewSession() async throws {
        let (_, provider) = provider()
        provider.opened(again: false)
        provider.opened(again: true)
        provider.opened(again: false)
        let status = try await provider.call(ServerPageProvider.statusOp, params: [:], context: page)
        #expect(status["approver"]?["session"] == 2)
    }

    /// The menu bar item hidden (Stop Serving) mid-switch: the source never settles that intent, so
    /// shown again the switch must not stay pending forever.
    @Test func stoppingDropsTheIntentsInFlight() async throws {
        let (_, provider) = provider(.healthyMac)
        try await call(provider, ServerPageProvider.sendOp, ["kind": "setEnabled", "on": false], as: person)
        var status = try await provider.call(ServerPageProvider.statusOp, params: [:], context: page)
        #expect(status["pending"]?["switching"] == true)
        provider.model.stop()
        provider.model.start()
        status = try await provider.call(ServerPageProvider.statusOp, params: [:], context: page)
        #expect(status["pending"]?["switching"] == false)
    }

    /// The card closed from outside (the panel dismissed, another card took its place) with a found
    /// server: reopened, the typed code stays and is looked up again, never showing the old facts.
    @Test func reopeningAfterAnOutsideCloseLooksTheCodeUpAgain() async throws {
        let (source, provider) = provider()
        try await call(provider, ServerPageProvider.setCodeOp, ["code": .string(MockServerScenario.offerCode)])
        source.deliverHeld()
        #expect(provider.model.addServerStep == .review(MockServerScenario.candidate))
        let sent = source.received.count
        provider.closed()
        // What the menu's openAddServer() does before the panel opens the card.
        provider.model.beginApproval()
        provider.opened(again: false)
        #expect(source.received.count == sent + 1)
        #expect(source.received.last?.kind == .lookupCode(MockServerScenario.offerCode))
        #expect(provider.model.addServerStep == .lookingUp)
        #expect(provider.model.approval.code == "7KQ4-M2XD")
    }

    /// A lookup still in flight when the card closed answers while it is closed: that answer never
    /// stands in for the reopening's own lookup.
    @Test func aLookupAnsweredWhileClosedIsLookedUpAgainOnReopen() async throws {
        let (source, provider) = provider()
        try await call(provider, ServerPageProvider.setCodeOp, ["code": .string(MockServerScenario.offerCode)])
        provider.closed()
        source.deliverHeld()
        let sent = source.received.count
        provider.model.beginApproval()
        provider.opened(again: false)
        #expect(source.received.count == sent + 1)
        #expect(provider.model.addServerStep == .lookingUp)
    }

    /// A server found before the page listened (no watch ran, so no change named the control): the
    /// card panel's native Approve shows as the page subscribes, not at the next change.
    @Test func theNativeControlShowsAServerFoundBeforeThePageListened() async throws {
        _ = NSApplication.shared
        let (source, provider) = provider()
        let panel = try #require(WebCardPanel(descriptor: .serverCards, cards: [provider]))
        panel.present(card: ServerPageProvider.route, over: nil, takeKeys: false)
        defer { panel.orderOut(nil) }
        #expect(panel.personButton.title != ServerStrings.approve)
        provider.model.setApprovalCode(MockServerScenario.offerCode)
        source.deliverHeld()
        #expect(provider.model.addServerStep == .review(MockServerScenario.candidate))
        let subscription = try await provider.subscribe(ServerPageProvider.changesStream, filter: [:], context: page) { _ in }
        defer { subscription.cancel() }
        #expect(!panel.personButton.isHidden)
        #expect(panel.personButton.title == ServerStrings.approve)
    }

    @Test func pagesHearChanges() async throws {
        let (source, provider) = provider(.healthyMac)
        var events = 0
        let subscription = try await provider.subscribe(ServerPageProvider.changesStream, filter: [:], context: page) { _ in events += 1 }
        defer { subscription.cancel() }
        source.load(.batteryLowDisk)
        for _ in 0..<50 where events == 0 { await Task.yield() }
        #expect(events > 0)
    }
}
