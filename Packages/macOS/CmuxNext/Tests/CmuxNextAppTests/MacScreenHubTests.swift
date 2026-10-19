import AppKit
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxScreenKit
import CryptoKit
import Foundation
import Testing

// Mac Screen with the device hub (docs/device-hub/PROTOCOL.md): device
// records, the viewer's cards per hub state and error code, View Only
// gating, the approval prompt's answers, the access pickers, the viewer's
// request flow and the pushes Mac Screen routes, and Settings > Devices'
// history and relay drafts.

/// Software keys: tests only (the app's keys are in the Secure Enclave).
private struct TestDeviceKeys: DeviceKeyMaterial {
    let signing = P256.Signing.PrivateKey()
    let agreement = P256.KeyAgreement.PrivateKey()
    var signingPublicKey: P256.Signing.PublicKey { signing.publicKey }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { agreement.publicKey }
    func signature(for message: Data) throws -> P256.Signing.ECDSASignature { try signing.signature(for: message) }
    func open(_ ciphertext: Data, encapsulatedKey: Data, info: Data) throws -> Data {
        var recipient = try HPKE.Recipient(privateKey: agreement, ciphersuite: RelaySealing.ciphersuite, info: info,
                                           encapsulatedKey: encapsulatedKey)
        return try recipient.open(ciphertext)
    }
}

private let hostID = "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff"

@MainActor
private func testHub() -> DeviceHub {
    let identity = DeviceIdentity(deviceID: UUID(), keys: TestDeviceKeys())
    let client = DeviceHubClient(baseURL: URL(string: "https://hub.invalid")!, identity: identity,
                                 tokens: DeviceHubAccountToken { throw DeviceHubError.notSignedIn })
    return DeviceHub(client: client, secrets: MemoryRelaySecretStore(), deviceName: "Test Mac")
}

private func ticket(_ id: String = "s1", role: SessionTicket.Role = .viewer, scope: SessionScope = .full,
                    peer: String = hostID) -> SessionTicket {
    SessionTicket(sessionId: id, ticket: "a.b.c", signalURL: URL(string: "wss://hub.invalid/v1/sessions/\(id)/ws")!, ice: [],
                  peer: .init(id: peer, name: "Studio", signingKey: "key"), role: role, scope: scope)
}

/// A signaling that is never opened.
private final class IdleSignaling: ScreenSignaling, @unchecked Sendable {
    func messages() -> AsyncThrowingStream<ScreenSignal, any Error> { AsyncThrowingStream { $0.finish() } }
    func send(_ signal: ScreenSignal) async throws {}
    func iceServers() async throws -> [ICEServerConfig] { [] }
    func close() {}
    var endsSessionOnClose: Bool { true }
}

struct MacScreenDeviceRecordTests {
    @Test func deviceRecordsRoundTripAndKeepTheLinkRecord() throws {
        let record = MacScreenRecord(deviceID: hostID.uppercased())
        #expect(record.deviceID == hostID)
        #expect(record.url.absoluteString == "cmux://mac-screen?device=\(hostID)")
        #expect(try #require(MacScreenRecord(url: record.url)) == record)
        // `mac=` (link pairing, DEV builds) still opens its Mac.
        let mac = UUID()
        #expect(MacScreenRecord(url: URL(string: "cmux://mac-screen?mac=\(mac.uuidString)")!)?.macID == mac)
        // A device wins over a Mac; a malformed device opens the home page.
        let both = try #require(MacScreenRecord(url: URL(string: "cmux://mac-screen?mac=\(mac.uuidString)&device=\(hostID)")!))
        #expect(both.deviceID == hostID && both.macID == nil)
        let malformed = try #require(MacScreenRecord(url: URL(string: "cmux://mac-screen?device=not-a-device")!))
        #expect(malformed.isHome)
    }

    @MainActor
    @Test func routesNameTheDeviceAndNothingElse() throws {
        let record = MacScreenRecord(deviceID: hostID)
        let route = MacScreenPages.route(of: record)
        #expect(route == "device:\(hostID)")
        #expect(MacScreenPages.record(route: route) == record)
        #expect(MacScreenPages.record(route: "device:nope") == nil)
        #expect(MacScreenPages.route(of: MacScreenRecord(macID: nil)) == "home")
    }
}

@MainActor
struct MacScreenHubCardTests {
    @Test func everyHubStateHasItsCard() {
        #expect(MacScreenPaneModel.hubCard(.idle) == .hubConnect)
        #expect(MacScreenPaneModel.hubCard(.requesting(.view)) == .hubRequesting(.view))
        #expect(MacScreenPaneModel.hubCard(.approved(sessionID: "s", scope: .full)) == .hubRequesting(.full))
        #expect(MacScreenPaneModel.hubCard(.waitingForApproval(sessionID: "s", scope: .full)) == .hubWaiting(.full))
        #expect(MacScreenPaneModel.hubCard(.streaming(sessionID: "s", scope: .full)) == nil)
        #expect(MacScreenPaneModel.hubCard(.declined(.view)) == .hubDeclined(.view))
        #expect(MacScreenPaneModel.hubCard(.refused(.hostOffline, requested: .full)) == .hubRefused(.hostOffline, requested: .full))
        #expect(MacScreenPaneModel.hubCard(.revoked(reason: "permission_changed")) == .hubRevoked(.permissionChanged))
        #expect(MacScreenPaneModel.hubCard(.ended(reason: "sharing_off")) == .hubEnded(.sharingOff))
    }

    @Test func refusalsFollowTheProtocolsCodes() {
        func refusal(_ code: String, status: Int = 403) -> MacScreenHubRefusal {
            MacScreenHubRefusal(.server(status: status, code: DeviceHubError.Code(code), message: ""))
        }
        #expect(refusal("permission_none") == .permissionNone)
        #expect(refusal("scope_exceeds_permission") == .scopeExceeds)
        #expect(refusal("host_offline", status: 409) == .hostOffline)
        #expect(refusal("not_shared") == .notShared)
        #expect(refusal("not_found", status: 404) == .notFound)
        #expect(refusal("internal", status: 500) == .other)
        #expect(MacScreenHubRefusal(.notSignedIn) == .notSignedIn)
        #expect(MacScreenHubRefusal(.transport("offline")) == .other)
    }

    @Test func endReasonsReadTheProtocolsAndThisAppsReasons() {
        #expect(MacScreenEndReason("permission_changed") == .permissionChanged)
        #expect(MacScreenEndReason("device_removed") == .deviceRemoved)
        #expect(MacScreenEndReason("sharing_off") == .sharingOff)
        #expect(MacScreenEndReason(MacScreenHubReason.hostStopped.rawValue) == .hostStopped)
        #expect(MacScreenEndReason(MacScreenHubReason.revoked.rawValue) == .hostStopped)
        #expect(MacScreenEndReason(MacScreenHubReason.viewerDisconnected.rawValue) == .viewerDisconnected)
        #expect(MacScreenEndReason(MacScreenHubReason.signedOut.rawValue) == .signedOut)
        #expect(MacScreenEndReason("bye") == .other)
        #expect(MacScreenEndReason(nil) == .other)
    }

    /// A device tab shows the stream's controls only while a session streams.
    @Test func deviceTabsShowStreamControlsOnlyWhileStreaming() {
        let viewer = MacScreenHubViewer(deviceID: hostID) { nil }
        let pane = MacScreenPane(hubDevice: viewer, name: "Studio", preferences: ScreenPreferences())
        #expect(pane.model.card == .hubConnect)
        #expect(!pane.model.showsStreamControls)
        viewer.phase = .streaming(sessionID: "s1", scope: .full)
        #expect(pane.model.showsStreamControls)
        #expect(pane.model.card != .hubConnect)
        pane.close()
    }
}

/// View Only sessions: the picture streams, nothing is sent.
@MainActor
struct MacScreenViewOnlyTests {
    @Test func aViewOnlyScreenTakesNoInput() {
        #expect(MacScreenPaneView.takesInput(gate: .open, card: nil))
        #expect(!MacScreenPaneView.takesInput(gate: .open, card: nil, viewOnly: true))
    }

    @Test func theSessionsScopeDecidesViewOnly() {
        let viewer = MacScreenHubViewer(deviceID: hostID) { nil }
        let pane = MacScreenPane(hubDevice: viewer, name: "Studio", preferences: ScreenPreferences())
        #expect(!pane.model.viewOnly)
        viewer.phase = .streaming(sessionID: "s1", scope: .view)
        #expect(pane.model.viewOnly)
        pane.view.syncInputGate()
        #expect(!pane.view.input.controlMode)
        #expect(!pane.view.input.acceptsPointer)
        viewer.phase = .streaming(sessionID: "s2", scope: .full)
        #expect(!pane.model.viewOnly)
        pane.close()
    }
}

struct MacScreenApprovalChoiceTests {
    private func answer(_ choice: MacScreenApprovalChoice, _ requested: SessionScope) -> String {
        let answer = choice.answer(requested: requested)
        return "\(answer.decision.rawValue)/\(answer.scope.rawValue)/\(answer.thenPermission?.rawValue ?? "-")"
    }

    @Test func eachButtonTellsTheHubTheRightDecisionAndScope() {
        #expect(answer(.deny, .full) == "deny/full/-")
        #expect(answer(.once, .view) == "once/view/-")
        #expect(answer(.once, .full) == "once/full/-")
        // Always Allow View Only lowers a Full request to a View session and permission.
        #expect(answer(.alwaysView, .full) == "always/view/-")
        #expect(answer(.alwaysView, .view) == "always/view/-")
        #expect(answer(.alwaysFull, .full) == "always/full/-")
        // A decision never raises the scope: a View request stays View, then the permission becomes Full.
        #expect(answer(.alwaysFull, .view) == "always/view/full")
    }
}

struct MacScreenAccessTests {
    @Test func pickerValuesAreTheProtocolsScopes() {
        #expect(MacScreenAccess.all.map(\.value) == ["none", "ask", "view", "full"])
        for access in MacScreenAccess.all {
            #expect(MacScreenAccess(value: access.value) == access)
            #expect(!access.title.isEmpty)
        }
        #expect(MacScreenAccess(value: "admin") == nil)
    }

    @Test func whatEachAccessGrantsWithoutAPrompt() {
        #expect(!MacScreenAccess(.none).grants(.view))
        #expect(!MacScreenAccess(.ask).grants(.view))
        #expect(MacScreenAccess(.view).grants(.view))
        #expect(!MacScreenAccess(.view).grants(.full))
        #expect(MacScreenAccess(.full).grants(.full))
    }
}

@MainActor
struct MacScreenHubViewerTests {
    @Test func requestAnswersMoveThePhase() {
        let viewer = MacScreenHubViewer(deviceID: hostID) { nil }
        viewer.phase = .requesting(.full)
        viewer.requestAnswered(.success(HubSession(id: "s1", state: .pending, scope: .full)), scope: .full, hub: nil)
        #expect(viewer.phase == .waitingForApproval(sessionID: "s1", scope: .full))
        viewer.phase = .requesting(.view)
        viewer.requestAnswered(.success(HubSession(id: "s2", state: .approved, scope: .view)), scope: .view, hub: nil)
        #expect(viewer.phase == .approved(sessionID: "s2", scope: .view))
        viewer.phase = .requesting(.full)
        viewer.requestAnswered(.failure(.server(status: 403, code: .permissionNone, message: "")), scope: .full, hub: nil)
        #expect(viewer.phase == .refused(.permissionNone, requested: .full))
    }

    /// A ticket can arrive before the request's answer: the answer then changes nothing.
    @Test func anAnswerAfterTheTicketIsIgnored() {
        let viewer = MacScreenHubViewer(deviceID: hostID) { nil }
        viewer.phase = .streaming(sessionID: "s1", scope: .full)
        viewer.requestAnswered(.success(HubSession(id: "s1", state: .approved, scope: .full)), scope: .full, hub: nil)
        #expect(viewer.phase == .streaming(sessionID: "s1", scope: .full))
    }

    @Test func ticketsMatchTheirSessionOrTheRequestedHost() {
        let viewer = MacScreenHubViewer(deviceID: hostID) { nil }
        viewer.phase = .requesting(.full)
        #expect(viewer.accepts(ticket("s9")))
        #expect(!viewer.accepts(ticket("s9", peer: "11111111-2222-3333-4444-555555555555")))
        #expect(!viewer.accepts(ticket("s9", role: .host)))
        viewer.phase = .waitingForApproval(sessionID: "s1", scope: .full)
        #expect(viewer.accepts(ticket("s1")))
        #expect(!viewer.accepts(ticket("s2")))
        viewer.phase = .idle
        #expect(!viewer.accepts(ticket("s1")))
    }

    @Test func aTicketStartsTheStreamWithItsSignalingOnce() throws {
        let hub = testHub()
        let viewer = MacScreenHubViewer(deviceID: hostID) { hub }
        let signaling = IdleSignaling()
        viewer.makeSignaling = { _, _ in signaling }
        var started = 0
        viewer.startStream = { started += 1 }
        viewer.phase = .waitingForApproval(sessionID: "s1", scope: .full)
        // The host lowered Full to View: the ticket's scope wins.
        viewer.accept(ticket("s1", scope: .view))
        #expect(viewer.phase == .streaming(sessionID: "s1", scope: .view))
        #expect(viewer.lastScope == .view)
        #expect(started == 1)
        #expect(viewer.takeSignaling() === signaling)
        #expect(viewer.takeSignaling() == nil)
    }

    @Test func denialsRevocationsAndEndsShowTheirCards() {
        let viewer = MacScreenHubViewer(deviceID: hostID) { nil }
        var stopped = 0
        viewer.stopStream = { stopped += 1 }
        viewer.phase = .waitingForApproval(sessionID: "s1", scope: .full)
        viewer.denied()
        #expect(viewer.phase == .declined(.full))
        viewer.phase = .streaming(sessionID: "s2", scope: .full)
        viewer.revoked(reason: "permission_changed")
        #expect(viewer.phase == .revoked(reason: "permission_changed"))
        #expect(stopped == 1)
        // The end that follows a revocation keeps the revocation's reason.
        viewer.ended(reason: "closed")
        #expect(viewer.phase == .revoked(reason: "permission_changed"))
        viewer.phase = .streaming(sessionID: "s3", scope: .view)
        viewer.ended(reason: "bye")
        #expect(viewer.phase == .ended(reason: "bye"))
        viewer.phase = .streaming(sessionID: "s4", scope: .view)
        viewer.hubGone()
        #expect(viewer.phase == .ended(reason: MacScreenHubReason.signedOut.rawValue))
    }

    @Test func withoutAHubARequestIsRefusedAsSignedOut() {
        let viewer = MacScreenHubViewer(deviceID: hostID) { nil }
        viewer.request(.view)
        #expect(viewer.phase == .refused(.notSignedIn, requested: .view))
        #expect(viewer.lastScope == .view)
    }
}

/// Mac Screen routes each `session.*` push to the device tab it names.
@MainActor
struct MacScreenHubPushTests {
    private func makePages() -> MacScreenPages {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        return MacScreenPages(store: MacScreenStore(file: file, secrets: MemoryMacScreenSecrets()))
    }

    @Test func pushesReachTheTabOfTheirSession() throws {
        let pages = makePages()
        pages.prepare("a", record: MacScreenRecord(deviceID: hostID), byPerson: false)
        pages.prepare("b", record: MacScreenRecord(deviceID: hostID), byPerson: false)
        _ = pages.makeView(for: "a")
        _ = pages.makeView(for: "b")
        let a = try #require(pages.tab("a")?.pane?.model.hub)
        let b = try #require(pages.tab("b")?.pane?.model.hub)
        // Restored or opened by automation: the Connect card, no request.
        #expect(a.phase == .idle && b.phase == .idle)
        #expect(pages.route(for: "a") == "device:\(hostID)")
        a.phase = .waitingForApproval(sessionID: "s1", scope: .full)
        b.phase = .waitingForApproval(sessionID: "s2", scope: .view)
        pages.handle(.sessionDenied(sessionID: "s1"))
        #expect(a.phase == .declined(.full))
        #expect(b.phase == .waitingForApproval(sessionID: "s2", scope: .view))
        b.phase = .streaming(sessionID: "s2", scope: .view)
        pages.handle(.sessionRevoked(sessionID: "s2", reason: "sharing_off"))
        #expect(b.phase == .revoked(reason: "sharing_off"))
        pages.tabClosed("a")
        pages.tabClosed("b")
    }

    @Test func signingOutEndsEveryDeviceSession() throws {
        let pages = makePages()
        pages.prepare("a", record: MacScreenRecord(deviceID: hostID), byPerson: false)
        _ = pages.makeView(for: "a")
        let viewer = try #require(pages.tab("a")?.pane?.model.hub)
        pages.hub = testHub()
        viewer.phase = .streaming(sessionID: "s1", scope: .full)
        pages.hub = nil
        #expect(viewer.phase == .ended(reason: MacScreenHubReason.signedOut.rawValue))
        pages.tabClosed("a")
    }
}

@MainActor
struct MacScreenDevicesSettingsTests {
    @Test func historyRowsShowMetadataAsPeopleReadIt() {
        let names = [hostID: "Studio", "v1": "Laptop"]
        let ended = AuditEntry(id: "e1", ts: Date(timeIntervalSince1970: 1_800_000_000), event: "ended", viewerId: "v1", hostId: hostID,
                               scope: "full", sessionId: "s1", detail: "bye", durationS: 1347)
        let row = MacScreenDevicesSettings.historyRow(ended, names: names, me: hostID)
        #expect(row.device == "Laptop" && row.host == "Studio")
        #expect(row.duration == "22m 27s")
        #expect(row.event == "ended" && !row.eventText.isEmpty)
        #expect(row.scope == SessionScope.full.title)
        let changed = AuditEntry(id: "e2", event: "permission_changed", viewerId: "gone", hostId: hostID, detail: "ask->full")
        let changedRow = MacScreenDevicesSettings.historyRow(changed, names: names, me: hostID)
        #expect(changedRow.detail == "\(MacScreenAccess(.ask).title) → \(MacScreenAccess(.full).title)")
        #expect(changedRow.device == MacScreenDevicesSettings.historyRow(changed, names: [:], me: hostID).device)
        #expect(changedRow.duration.isEmpty && changedRow.time == "—")
        #expect(MacScreenDevicesSettings.durationText(8) == "8s")
        #expect(MacScreenDevicesSettings.durationText(3840) == "1h 4m")
    }

    @Test func relayDraftsKeepTheSavedSecretOnlyWhenLeftEmpty() {
        typealias Draft = MacScreenDevicesSettings.Run.RelayDraft
        func draft(_ mode: String, secret: String? = nil, username: String? = nil, password: String? = nil) -> Draft {
            Draft(id: "r1", name: "Home", urls: [" turns:turn.example.com:5349 ", "", "turn:turn.example.com:3478?transport=udp"],
                  mode: mode, secret: secret, username: username, password: password, enabled: true, priority: 0)
        }
        #expect(MacScreenDevicesSettings.secret(draft("shared_secret", secret: "s3cret"), existing: nil) == .sharedSecret("s3cret"))
        #expect(MacScreenDevicesSettings.secret(draft("shared_secret"), existing: .sharedSecret("old")) == .sharedSecret("old"))
        #expect(MacScreenDevicesSettings.secret(draft("shared_secret"), existing: .static(username: "u", password: "p")) == nil)
        #expect(MacScreenDevicesSettings.secret(draft("static", username: "u", password: "p"), existing: nil) == .static(username: "u", password: "p"))
        #expect(MacScreenDevicesSettings.secret(draft("static", username: "u"), existing: nil) == nil)
        #expect(MacScreenDevicesSettings.secret(draft("static"), existing: .static(username: "a", password: "b")) == .static(username: "a", password: "b"))
        #expect(MacScreenDevicesSettings.urls(draft("static")) == ["turns:turn.example.com:5349", "turn:turn.example.com:3478?transport=udp"])
    }

    @Test func checkRelayOutcomesReadAsSuccessOrFailure() {
        #expect(MacScreenDevicesSettings.checkResult(.relayed).tone == "success")
        #expect(MacScreenDevicesSettings.checkResult(.noRelayCandidate).tone == "danger")
        #expect(MacScreenDevicesSettings.checkResult(.failed("x")).tone == "danger")
        #expect(ICERelayCheck.isRelayCandidate("candidate:1 1 udp 2 203.0.113.9 3478 typ relay raddr 0.0.0.0 rport 0"))
        #expect(!ICERelayCheck.isRelayCandidate("candidate:1 1 udp 2 192.168.1.2 5000 typ host"))
    }

    /// The state never carries a secret, even with relays this Mac can open.
    @Test func theStateHoldsNoSecrets() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file, secrets: MemoryMacScreenSecrets()))
        let settings = MacScreenDevicesSettings(pages: pages)
        pages.hubConfigured = true
        #expect(settings.state.available && settings.state.thisDevice == nil)
        pages.hub = testHub()
        let data = try JSONEncoder().encode(settings.state)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"signIn\":null"))
        #expect(!text.contains("secret\":\""))
        pages.hubConfigured = false
        #expect(!settings.state.available)
        pages.hub = nil
    }
}
