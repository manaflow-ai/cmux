import AppKit
@testable import CmuxNextPages
@testable import CmuxNextServer
import CmuxNextSettings
import Foundation
import Testing

/// The server pages' provider (webviews/src/pages/server-cards/server): the model's state as page
/// JSON (the offer's QR image, never its key fingerprint), and the changes only a person may make
/// (the switch, Show Pairing Code, Fix, Revoke) refused without their own click or key in the page.
/// No page op adds a server: Add Server is a native card (AddServerDialogTests).
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
        for op in ["setCode", "approve", "setRunChief"] {
            await #expect(throws: PageError.self) { try await call(provider, "cmux.server.approver.\(op)", ["code": "7KQ4M2XD"], as: person) }
        }
        #expect(source.received.isEmpty)
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
