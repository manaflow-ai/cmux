import AppKit
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextServer
import CmuxNextWakeups
import CmuxScreenKit
import CmuxNextTestSupport
import CryptoKit
import Foundation
import Testing
import CmuxNextWakeupsTestSupport

// Mac Screen with the device hub (docs/device-hub/PROTOCOL.md): device
// records, the viewer's cards per hub state and error code, View Only
// gating, the approval prompt's answers, the access pickers, the viewer's
// request flow and the pushes Mac Screen routes, and Settings > Devices'
// history and relay drafts.

/// Software keys: tests only (the app's keys are in the Secure Enclave).
nonisolated private struct TestDeviceKeys: DeviceKeyMaterial {
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

/// Calls in order (a class: actor-isolated closures cannot capture a mutable local).
@MainActor
private final class CallLog {
    var items: [String] = []
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
nonisolated private final class IdleSignaling: ScreenSignaling, @unchecked Sendable {
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
        #expect(MacScreenPaneModel.hubCard(.revoked(reason: "permission_revoked")) == .hubRevoked(.permissionRevoked))
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

    @Test func endReasonsReadTheProtocolsAuthoritativeReasons() {
        #expect(MacScreenEndReason("permission_revoked") == .permissionRevoked)
        #expect(MacScreenEndReason("permission_changed") == .permissionRevoked)
        #expect(MacScreenEndReason("device_removed:viewer") == .viewerRemoved)
        #expect(MacScreenEndReason("device_removed:host") == .hostRemoved)
        #expect(MacScreenEndReason("device_removed") == .deviceRemoved)
        #expect(MacScreenEndReason("sharing_off") == .sharingOff)
        #expect(MacScreenEndReason("host_stopped") == .hostStopped)
        #expect(MacScreenEndReason("viewer_disconnected") == .viewerDisconnected)
        #expect(MacScreenEndReason("signed_out") == .signedOut)
        #expect(MacScreenEndReason("peer_offline") == .peerOffline)
        #expect(MacScreenEndReason("failed") == .failed)
        #expect(MacScreenEndReason("expired") == .expired)
        #expect(MacScreenEndReason("approve_failed") == .approveFailed)
        #expect(MacScreenEndReason.approveFailed.text(host: "Mac mini 2").contains("Mac mini 2"))
        #expect(MacScreenEndReason("bye") == .other)
        #expect(MacScreenEndReason(nil) == .other)
        #expect(MacScreenHubReason.hostStopped.rawValue == "host_stopped")
        #expect(MacScreenHubReason.viewerDisconnected.rawValue == "viewer_disconnected")
        #expect(MacScreenHubReason.signedOut.rawValue == "signed_out")
    }

    /// The viewer's card names the host device; "This Mac" is only ever the viewer itself.
    @Test func endTextsNameTheHost() {
        for reason: MacScreenEndReason in [.permissionRevoked, .hostRemoved, .sharingOff, .hostStopped, .peerOffline] {
            #expect(reason.text(host: "Mac mini 2").contains("Mac mini 2"))
        }
        #expect(MacScreenEndReason.hostStopped.text(host: "Mac mini 2") != MacScreenEndReason.other.text(host: "Mac mini 2"))
        #expect(MacScreenEndReason.permissionRevoked.removesAccess && MacScreenEndReason.viewerRemoved.removesAccess)
        #expect(!MacScreenEndReason.hostStopped.removesAccess && !MacScreenEndReason.sharingOff.removesAccess)
    }

    /// A failed stream says why: a relay's refusal or unreachability, a relay-only path, or the host by name.
    @Test func failedCardsSayWhy() {
        let refused = ICECandidateError(code: 401, url: "turn:relay.example:3478", text: "Unauthorized")
        let unreachable = ICECandidateError(code: 701, url: "turns:relay.example:5349", text: "")
        let generic = MacScreenPaneModel.failedDetail(relayErrors: [], relayOnly: false, hubTab: true, name: "Mac mini 2")
        // This Mac lost its own link to the hub: the card says so, not that the host is away.
        let ownLink = MacScreenPaneModel.failedDetail(relayErrors: [], relayOnly: false, hubTab: true, name: "Mac mini 2", hubOnline: false)
        #expect(ownLink != generic && !ownLink.contains("Mac mini 2"))
        #expect(generic.contains("Mac mini 2"))
        let refusedText = MacScreenPaneModel.failedDetail(relayErrors: [unreachable, refused], relayOnly: false, hubTab: true, name: "M")
        let unreachableText = MacScreenPaneModel.failedDetail(relayErrors: [unreachable], relayOnly: true, hubTab: true, name: "M")
        let relayOnly = MacScreenPaneModel.failedDetail(relayErrors: [], relayOnly: true, hubTab: true, name: "M")
        #expect(Set([generic, refusedText, unreachableText, relayOnly]).count == 4)
        #expect(ICERelayCheck.outcome([refused, unreachable]) == .refusedCredentials)
        #expect(ICERelayCheck.outcome([unreachable]) == .unreachable)
        // No relay address and no 401 before the deadline: the relay can't be reached.
        #expect(ICERelayCheck.outcome([]) == .unreachable)
        #expect(!ICECandidateError(code: 701, url: "stun:stun.example:3478", text: "").isTURN)
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
        viewer.revoked(reason: "permission_revoked")
        #expect(viewer.phase == .revoked(reason: "permission_revoked"))
        #expect(stopped == 1)
        // The end that follows a revocation keeps the revocation's reason.
        viewer.ended(reason: "closed")
        #expect(viewer.phase == .revoked(reason: "permission_revoked"))
        viewer.phase = .streaming(sessionID: "s3", scope: .view)
        viewer.ended(reason: "bye")
        #expect(viewer.phase == .ended(reason: "bye"))
        viewer.phase = .streaming(sessionID: "s4", scope: .view)
        viewer.hubGone()
        #expect(viewer.phase == .ended(reason: MacScreenHubReason.signedOut.rawValue))
    }

    /// Disconnect tells the hub why (`/end viewer_disconnected`) before the stream stops.
    @Test func disconnectEndsOnTheHubBeforeTheStreamStops() async {
        let hub = testHub()
        let viewer = MacScreenHubViewer(deviceID: hostID) { hub }
        let order = CallLog()
        viewer.endSession = { _, id, reason in order.items.append("end \(id) \(reason)") }
        viewer.stopStream = { order.items.append("stop") }
        viewer.phase = .streaming(sessionID: "s1", scope: .full)
        await withCheckedContinuation { done in
            viewer.disconnect(reason: .viewerDisconnected) { done.resume() }
            #expect(viewer.phase == .ended(reason: "viewer_disconnected"))
        }
        #expect(order.items == ["end s1 viewer_disconnected", "stop"])
    }

    /// A stream that failed keeps its card (which says why) when the hub's end for it arrives.
    @Test func aFailedStreamKeepsItsCard() {
        let hub = testHub()
        let viewer = MacScreenHubViewer(deviceID: hostID) { hub }
        viewer.endSession = { _, _, _ in }
        viewer.phase = .streaming(sessionID: "s1", scope: .full)
        viewer.streamFailed()
        // The tab's ended state shows in the hub state too (debug.device_hub), not "streaming".
        #expect(viewer.phase == .streamFailed(sessionID: "s1", scope: .full))
        #expect(viewer.phase.streamingScope == nil && viewer.phase.sessionID == "s1")
        #expect(MacScreenPaneModel.hubCard(viewer.phase) == nil)
        viewer.revoked(reason: "failed")
        #expect(viewer.phase == .streamFailed(sessionID: "s1", scope: .full))
    }

    /// A dropped stream waits before telling the hub "failed", so a host's
    /// cause (signed_out, sharing_off) that is on its way wins at the hub too.
    @Test func aDroppedStreamWaitsBeforeEndingAsFailed() async throws {
        let hub = testHub()
        let viewer = MacScreenHubViewer(deviceID: hostID) { hub }
        let ends = CallLog()
        viewer.endSession = { _, id, reason in ends.items.append("\(id) \(reason)") }
        let clock = ManualClock()
        viewer.failureEnd = DemandTimer(owner: "test.mac-screen.hub-failure-grace", clock: clock)
        viewer.phase = .streaming(sessionID: "s1", scope: .view)
        viewer.streamFailed()
        #expect(ends.items.isEmpty)
        viewer.revoked(reason: "signed_out")
        #expect(!viewer.failureEnd.isScheduled)
        #expect(ends.items.isEmpty)
        #expect(viewer.phase == .revoked(reason: "signed_out"))
        // No push comes: the hub hears "failed" after the grace.
        viewer.phase = .streaming(sessionID: "s2", scope: .view)
        viewer.streamFailed()
        try await clock.waitForSleeper()
        #expect(ends.items.isEmpty)
        clock.advance(by: viewer.failureGrace)
        for _ in 0..<500 where ends.items.isEmpty { await Task.yield() }
        #expect(ends.items == ["s2 failed"])
    }

    /// A stream that failed while this Mac's hub link was down keeps saying so after the link returns.
    @Test func aLostLinkFailureStaysExplained() {
        let viewer = MacScreenHubViewer(deviceID: hostID) { testHub() }
        viewer.endSession = { _, _, _ in }
        viewer.failureGrace = .seconds(60)
        viewer.phase = .streaming(sessionID: "s1", scope: .view)
        viewer.streamFailed()
        #expect(viewer.failedWhileOffline)
        viewer.request(.view)
        #expect(!viewer.failedWhileOffline)
    }

    /// Connect Again asks for what the host now allows: Full re-granted means Full, View means View.
    @Test func connectAgainFollowsTheCurrentPermission() {
        #expect(MacScreenHubViewer.scopeToRequest(last: .view, access: .full) == .full)
        #expect(MacScreenHubViewer.scopeToRequest(last: .full, access: .view) == .view)
        #expect(MacScreenHubViewer.scopeToRequest(last: .full, access: .ask) == .full)
        #expect(MacScreenHubViewer.scopeToRequest(last: .view, access: nil) == .view)
    }

    /// A permission raised again after a revocation never reads as removed access.
    @Test func reGrantedAccessIsNotRemoved() {
        #expect(MacScreenPaneModel.hubCard(.revoked(reason: "permission_revoked"), access: .full) == .hubRevoked(.accessChanged))
        #expect(MacScreenPaneModel.hubCard(.revoked(reason: "permission_revoked"), access: .ask) == .hubRevoked(.accessChanged))
        #expect(!MacScreenEndReason.accessChanged.removesAccess && MacScreenEndReason.accessChanged.canReconnect)
    }

    /// A device that left the user's devices: no Try Again.
    @Test func notFoundOffersNoRetry() {
        #expect(!MacScreenHubRefusal.notFound.canRetry)
        #expect(MacScreenHubRefusal.hostOffline.canRetry && MacScreenHubRefusal.notShared.canRetry)
    }

    /// The host's reason wins over a stream that dropped a moment before it arrived (View scope too).
    @Test func theHostsReasonWinsOverTheDroppedStream() {
        for scope: SessionScope in [.view, .full] {
            let hub = testHub()
            let viewer = MacScreenHubViewer(deviceID: hostID) { hub }
            viewer.endSession = { _, _, _ in }
            viewer.failureGrace = .seconds(60)
            viewer.phase = .streaming(sessionID: "s1", scope: scope)
            viewer.streamFailed()
            viewer.revoked(reason: "sharing_off")
            #expect(viewer.phase == .revoked(reason: "sharing_off"))
            viewer.phase = .streaming(sessionID: "s2", scope: scope)
            viewer.streamFailed()
            viewer.ended(reason: "host_stopped")
            #expect(viewer.phase == .ended(reason: "host_stopped"))
        }
    }

    /// A ticket that beats the request's HTTP answer: the answer that comes back
    /// afterwards never ends the session it started.
    @Test func aLateAnswerNeverEndsTheSessionItStarted() async {
        let hub = testHub()
        let viewer = MacScreenHubViewer(deviceID: hostID) { hub }
        let ends = CallLog()
        viewer.endSession = { _, id, reason in ends.items.append("\(id) \(reason)") }
        viewer.phase = .streaming(sessionID: "s2", scope: .full)
        #expect(viewer.requestReturned(.success(HubSession(id: "s2", state: .approved, scope: .full)), scope: .full, hub: hub,
                                       cancelled: true) == nil)
        #expect(viewer.phase == .streaming(sessionID: "s2", scope: .full))
        // A request the person cancelled while it was out does end its session.
        viewer.phase = .idle
        await viewer.requestReturned(.success(HubSession(id: "s3", state: .pending, scope: .view)), scope: .view, hub: hub,
                                     cancelled: true)?.value
        #expect(viewer.phase == .idle)
        #expect(ends.items == ["s3 viewer_disconnected"])
    }

    /// A stalled stream whose host the hub lists offline ends now; either alone does not
    /// (a host's short hub drop leaves a live stream alone, and a stall may recover).
    @Test func aStalledStreamOfAnOfflineHostEnds() {
        let viewer = MacScreenHubViewer(deviceID: hostID) { nil }
        let stops = CallLog()
        viewer.stopStream = { stops.items.append("stop") }
        viewer.phase = .streaming(sessionID: "s1", scope: .full)
        viewer.hostOnlineChanged(false)
        #expect(viewer.phase == .streaming(sessionID: "s1", scope: .full))
        viewer.hostOnlineChanged(true)
        viewer.streamStalled(true)
        #expect(viewer.phase == .streaming(sessionID: "s1", scope: .full))
        viewer.hostOnlineChanged(false)
        #expect(viewer.phase == .ended(reason: "peer_offline") && stops.items == ["stop"])
    }

    /// The viewer gives up with the hub: a request nobody answers ends at the five-minute expiry.
    @Test func anUnansweredRequestExpires() async throws {
        let hub = testHub()
        let viewer = MacScreenHubViewer(deviceID: hostID) { hub }
        let ends = CallLog()
        viewer.endSession = { _, id, reason in ends.items.append("\(id) \(reason)") }
        let clock = ManualClock()
        viewer.approvalExpiry = DemandTimer(owner: "test.mac-screen.hub-request-expiry", clock: clock)
        viewer.phase = .requesting(.view)
        viewer.requestAnswered(.success(HubSession(id: "s1", state: .pending, scope: .view)), scope: .view, hub: hub)
        #expect(viewer.phase == .waitingForApproval(sessionID: "s1", scope: .view))
        try await clock.waitForSleeper()
        clock.advance(by: viewer.approvalTimeout)
        for _ in 0..<500 where viewer.phase != .ended(reason: "expired") { await Task.yield() }
        #expect(viewer.phase == .ended(reason: "expired"))
        #expect(ends.items == ["s1 expired"])
    }

    /// Full lowered to View: the card says the access changed and offers View Only.
    @Test func accessLoweredToViewIsNotRemoved() {
        #expect(MacScreenPaneModel.hubCard(.revoked(reason: "permission_revoked"), access: .view) == .hubAccessLowered)
        #expect(MacScreenPaneModel.hubCard(.revoked(reason: "permission_revoked"), access: MacScreenAccess(.none).scope)
            == .hubRevoked(.permissionRevoked))
    }

    /// A removed host is gone: its card offers no Connect Again.
    @Test func removedDevicesOfferNoReconnect() {
        #expect(!MacScreenEndReason.hostRemoved.canReconnect && !MacScreenEndReason.viewerRemoved.canReconnect)
        #expect(MacScreenEndReason.hostStopped.canReconnect && MacScreenEndReason.permissionRevoked.canReconnect)
    }

    /// None means the host blocked this device: no Ask for Access (the hub refuses it).
    @Test func noAskForAccessAtNone() {
        #expect(!MacScreenAccess(.none).allowsRequests)
        #expect(MacScreenAccess(.ask).allowsRequests && MacScreenAccess(.view).allowsRequests && MacScreenAccess(.full).allowsRequests)
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
        return MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork())
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

    /// A restored device tab is titled with the device's last known name before the hub answers.
    @Test func restoredDeviceTabsTakeTheirSavedName() async {
        let pages = makePages()
        await pages.store.load()
        pages.store.rememberDeviceNames([hostID: "Mac mini 2"])
        pages.restore("device:\(hostID)", for: "restored")
        #expect(pages.title(for: "restored") == "Mac mini 2")
        pages.restore("device:11111111-2222-3333-4444-555555555555", for: "unknown")
        #expect(pages.title(for: "unknown") == "Mac")
    }

    /// This Mac removed from the user's devices: its sessions end with that reason, not "signed out".
    @Test func aRemovedViewerSaysItWasRemoved() throws {
        let pages = makePages()
        pages.prepare("a", record: MacScreenRecord(deviceID: hostID), byPerson: false)
        _ = pages.makeView(for: "a")
        let viewer = try #require(pages.tab("a")?.pane?.model.hub)
        pages.hub = testHub()
        viewer.phase = .streaming(sessionID: "s1", scope: .full)
        pages.endHubSessions(reason: "device_removed:viewer")
        pages.hub = nil
        #expect(viewer.phase == .ended(reason: "device_removed:viewer"))
        #expect(MacScreenPaneModel.hubCard(viewer.phase) == .hubEnded(.viewerRemoved))
        pages.tabClosed("a")
    }

    /// A restored, unselected device tab's strip title comes from its route and the saved name.
    @Test func routesTitleRestoredTabsBeforeTheirView() async {
        let pages = makePages()
        await pages.store.load()
        pages.store.rememberDeviceNames([hostID: "Mac mini 2"])
        #expect(pages.title(forRoute: "device:\(hostID)") == "Mac mini 2")
        #expect(pages.title(forRoute: "home") == MacScreenPages.homeTitle)
        #expect(pages.title(forRoute: nil) == nil)
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
        // End reasons name the devices.
        let stopped = AuditEntry(id: "e3", event: "ended", viewerId: "v1", hostId: hostID, detail: "host_stopped")
        #expect(MacScreenDevicesSettings.historyRow(stopped, names: names, me: hostID).detail.contains("Studio"))
        // A removed device no longer listed: never "Removed device was removed".
        let unknownRemoved = AuditEntry(id: "e6", event: "ended", viewerId: "gone", hostId: hostID, detail: "device_removed:viewer")
        #expect(!MacScreenDevicesSettings.historyRow(unknownRemoved, names: names, me: hostID).detail
            .contains(MacScreenDevicesSettings.historyRow(unknownRemoved, names: names, me: hostID).device))
        let removed = AuditEntry(id: "e4", event: "ended", viewerId: "v1", hostId: hostID, detail: "device_removed:viewer")
        #expect(MacScreenDevicesSettings.historyRow(removed, names: names, me: hostID).detail.contains("Laptop"))
        let disconnected = AuditEntry(id: "e5", event: "ended", viewerId: "v1", hostId: hostID, detail: "viewer_disconnected")
        #expect(MacScreenDevicesSettings.historyRow(disconnected, names: names, me: hostID).detail.contains("Laptop"))
        // Devices joining and leaving (the backend's per-device audit): the detail names the device.
        // A removed device's name comes from the entry itself when no list knows it.
        var gone = AuditEntry(id: "e11", event: "ended", viewerId: "gone-id", hostId: hostID, detail: "device_removed:viewer")
        gone.viewerName = "Old Laptop"
        let goneRow = MacScreenDevicesSettings.historyRow(gone, names: names, me: hostID)
        #expect(goneRow.device == "Old Laptop" && goneRow.detail.contains("Old Laptop"))
        // The backend names the device in deviceId.
        let joined = AuditEntry(id: "e9", event: "device_added", deviceId: "v1")
        let joinedRow = MacScreenDevicesSettings.historyRow(joined, names: names, me: hostID)
        #expect(joinedRow.detail.contains("Laptop") && joinedRow.device == "Laptop")
        // A socket close is no longer an end reason: History shows the raw word only for an unknown one.
        let bye = AuditEntry(id: "e10", event: "ended", viewerId: "v1", hostId: hostID, detail: "bye")
        #expect(!MacScreenDevicesSettings.historyRow(bye, names: names, me: hostID).detail.isEmpty)
        let added = AuditEntry(id: "e7", event: "device_added", viewerId: nil, hostId: "v1")
        let addedRow = MacScreenDevicesSettings.historyRow(added, names: names, me: hostID)
        #expect(addedRow.detail.contains("Laptop") && !addedRow.eventText.isEmpty && addedRow.tone == "success")
        let left = AuditEntry(id: "e8", event: "device_removed", viewerId: "v1", hostId: nil)
        #expect(MacScreenDevicesSettings.historyRow(left, names: names, me: hostID).detail.contains("Laptop"))
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
        let refused = MacScreenDevicesSettings.checkResult(.refusedCredentials).text
        let unreachable = MacScreenDevicesSettings.checkResult(.unreachable).text
        let none = MacScreenDevicesSettings.checkResult(.noRelayCandidate).text
        #expect(Set([refused, unreachable, none]).count == 3)
        #expect(ICERelayCheck.isRelayCandidate("candidate:1 1 udp 2 203.0.113.9 3478 typ relay raddr 0.0.0.0 rport 0"))
        #expect(!ICERelayCheck.isRelayCandidate("candidate:1 1 udp 2 192.168.1.2 5000 typ host"))
    }

    /// The state never carries a secret, even with relays this Mac can open.
    @Test func theStateHoldsNoSecrets() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork())
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

/// The host's controls tell the hub the cause before anything closes here.
@MainActor
struct MacScreenHubHostOrderTests {
    /// A signaling that stays open until closed (the host serves it meanwhile).
    nonisolated final class OpenSignaling: ScreenSignaling, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncThrowingStream<ScreenSignal, any Error>.Continuation?
        func messages() -> AsyncThrowingStream<ScreenSignal, any Error> {
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: ScreenSignal.self, throwing: (any Error).self)
            lock.withLock { self.continuation = continuation }
            return stream
        }
        func send(_ signal: ScreenSignal) async throws {}
        func iceServers() async throws -> [ICEServerConfig] { [] }
        func close() { lock.withLock { continuation }?.finish() }
        var endsSessionOnClose: Bool { true }
    }

    private func serving() -> (MacScreenHubHost, DeviceHub) {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork())
        let hub = testHub()
        let host = pages.hubHost
        host.hub = { hub }
        host.makeSignaling = { _, _ in OpenSignaling() }
        host.serve(ticket("s1", role: .host, scope: .full, peer: "v1"))
        return (host, hub)
    }

    /// The one-line join's consent (app-owned Mac Screen, so acpmux cannot gate it): with the Labs switch
    /// on and an acpmux without `machine-consent-v1`, a ticket is ended unserved and the one-time sheet shows.
    @Test func aDaemonWithoutConsentSupportRefusesMacScreenAndShowsTheSheet() async {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork())
        let hub = testHub()
        let host = pages.hubHost
        host.hub = { hub }
        let made = CallLog(), ends = CallLog()
        host.makeSignaling = { _, _ in
            made.items.append("signaling")
            return OpenSignaling()
        }
        host.endSession = { _, id, reason in ends.items.append("\(id) \(reason)") }
        let fake = JoinConsentTests.Fake()
        fake.capable = false
        let consent = JoinConsentModel(services: fake.services())
        await consent.refresh()
        host.consentGate = { await consent.allowsMacScreen(control: $0.scope == .full, requester: $0.peer.name) }
        consent.changed = { [weak consent, weak host] in host?.consentChanged { consent?.permitsMacScreen(control: $0 == .full) ?? false } }
        host.serve(ticket("s1", role: .host, scope: .view, peer: "v1"))
        for _ in 0..<1000 where ends.items.isEmpty { await Task.yield() }
        #expect(host.session == nil && made.items.isEmpty, "nothing served")
        #expect(ends.items == ["s1 failed"])
        #expect(consent.ask == JoinConsentRefusal(requester: "Studio", surface: .screen))
        // The same Mac with consent support and Screen sharing on serves the view (read when it arrives).
        fake.capable = true
        fake.record.screen = true
        host.serve(ticket("s2", role: .host, scope: .view, peer: "v1"))
        for _ in 0..<1000 where host.session == nil { await Task.yield() }
        #expect(host.session?.id == "s2" && made.items == ["signaling"])
        // Turning Screen sharing off stops the running session here at once, before the hub answers.
        let hubAnswers = JoinConsentTests.Gate()
        host.endSession = { _, id, reason in
            ends.items.append("\(id) \(reason)")
            await hubAnswers.wait()
        }
        #expect(await consent.set(.screen, on: false) == nil)
        #expect(host.session == nil)
        for _ in 0..<1000 where ends.items.count < 2 { await Task.yield() }
        #expect(ends.items == ["s1 failed", "s2 host_stopped"])
        hubAnswers.open()
    }

    /// Consent reads that answer out of order: the newer ticket serves and the older one is replaced,
    /// never the other way around.
    @Test func anOlderTicketWhoseReadAnswersLaterNeverReplacesANewerOne() async {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork())
        let hub = testHub()
        let host = pages.hubHost
        host.hub = { hub }
        host.makeSignaling = { _, _ in OpenSignaling() }
        let ends = CallLog()
        host.endSession = { _, id, reason in ends.items.append("\(id) \(reason)") }
        let first = JoinConsentTests.Gate(), second = JoinConsentTests.Gate()
        host.consentGate = { ticket in
            await (ticket.sessionId == "s1" ? first : second).wait()
            return true
        }
        host.serve(ticket("s1", role: .host, scope: .view, peer: "v1"))
        host.serve(ticket("s2", role: .host, scope: .view, peer: "v2"))
        second.open()
        for _ in 0..<1000 where host.session == nil { await Task.yield() }
        #expect(host.session?.id == "s2")
        first.open()
        for _ in 0..<1000 where ends.items.isEmpty { await Task.yield() }
        #expect(host.session?.id == "s2", "the newer session keeps serving")
        #expect(ends.items == ["s1 replaced"])
        host.sessionOver("s2")
    }

    /// Two deliveries of one session, their consent reads answering in either order: the newer delivery
    /// decides it, and the older one never ends or serves it.
    @Test(arguments: [true, false])
    func twoDeliveriesOfOneSessionAreDecidedByTheNewer(newerFirst: Bool) async {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork())
        let hub = testHub()
        let host = pages.hubHost
        host.hub = { hub }
        host.makeSignaling = { _, _ in OpenSignaling() }
        let ends = CallLog()
        host.endSession = { _, id, reason in ends.items.append("\(id) \(reason)") }
        var gates: [JoinConsentTests.Gate] = []
        host.consentGate = { _ in
            let gate = JoinConsentTests.Gate()
            gates.append(gate)
            await gate.wait()
            return gates.count == 2 && gate === gates[1] // only the newer delivery's read allows
        }
        host.serve(ticket("s1", role: .host, scope: .view, peer: "v1"))
        host.serve(ticket("s1", role: .host, scope: .view, peer: "v1"))
        for _ in 0..<1000 where gates.count < 2 { await Task.yield() }
        let order = newerFirst ? [gates[1], gates[0]] : [gates[0], gates[1]]
        for gate in order {
            gate.open()
            for _ in 0..<50 { await Task.yield() }
        }
        #expect(host.session?.id == "s1", "served once, by the newer delivery")
        #expect(ends.items.isEmpty, "the older delivery ends nothing")
        host.sessionOver("s1")
    }

    @Test func stopSharingEndsATicketStillWaitingForConsent() async {
        let (host, _) = serving()
        let ends = CallLog()
        host.endSession = { _, id, reason in ends.items.append("\(id) \(reason)") }
        let read = JoinConsentTests.Gate()
        host.consentGate = { _ in
            await read.wait()
            return true
        }
        host.serve(ticket("s2", role: .host, scope: .view, peer: "v2"))
        await host.stopSession()?.value
        read.open()
        for _ in 0..<1000 where ends.items.count < 2 { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(host.session == nil, "the waiting ticket never serves")
        #expect(Set(ends.items) == ["s1 host_stopped", "s2 host_stopped"])
    }

    @Test func revokeSetsNoneAndWaitsForTheHubsRevocation() async {
        let (host, _) = serving()
        let revoked = CallLog()
        host.revokePermission = { _, viewer in revoked.items.append(viewer) }
        await host.revokeViewer()?.value
        #expect(revoked.items == ["v1"])
        // Still serving: the hub's session.revoked push closes it, with the reason.
        #expect(host.session?.id == "s1")
        host.sessionOver("s1")
        #expect(host.session == nil)
    }

    @Test func stopSharingEndsOnTheHubThenCloses() async {
        let (host, _) = serving()
        let calls = CallLog()
        host.endSession = { _, id, reason in
            // Still serving while the hub hears why.
            calls.items.append("\(id) \(reason) \(host.session?.id ?? "closed")")
        }
        await host.stopSession()?.value
        #expect(calls.items == ["s1 host_stopped s1"])
        #expect(host.session == nil)
    }
}

/// The host's approval prompt is visible every time, not only the first.
@MainActor @Suite(.closesItsWindows)
struct MacScreenApprovalPanelTests {
    @Test(arguments: [false, true])
    func settlingTheLastRequestClosesItsPanel(observerFirst: Bool) throws {
        let prompt = MacScreenApprovalPrompt()
        defer { prompt.update([]) }
        let hub = testHub()
        let request = SessionRequest(id: "settled", viewerId: "v1", viewerName: "Laptop", scope: .view)
        prompt.update([request])
        _ = try #require(prompt.panelFrame)
        // decide() has removed the request from the hub. Its pending-request observer may
        // run before the answer's settlement, or afterward; both must close the last panel.
        if observerFirst { prompt.update(hub.pendingRequests) }
        prompt.settle(request.id, hub: hub)
        #expect(prompt.current == nil)
        #expect(prompt.panelFrame == nil)
        prompt.update(hub.pendingRequests)
        #expect(prompt.panelFrame == nil)

        // Closing drops the old panel; a later request still gets a usable replacement.
        prompt.update([SessionRequest(id: "next", viewerId: "v1", viewerName: "Laptop", scope: .full)])
        _ = try #require(prompt.panelFrame)
    }

    @Test func everyPromptHasAVisibleFrame() throws {
        let prompt = MacScreenApprovalPrompt()
        defer { prompt.update([]) }
        let first = SessionRequest(id: "s1", viewerId: "v1", viewerName: "Laptop", viewerKeyFingerprint: String(repeating: "ab", count: 32), scope: .view)
        let second = SessionRequest(id: "s2", viewerId: "v1", viewerName: "Laptop", scope: .full)
        prompt.update([first])
        let one = try #require(prompt.panelFrame)
        prompt.update([])
        #expect(prompt.panelFrame == nil)
        prompt.update([second])
        let two = try #require(prompt.panelFrame)
        for frame in [one, two] {
            #expect(frame.width >= 300 && frame.height >= 100)
            if let screen = NSScreen.main ?? NSScreen.screens.first { #expect(screen.frame.intersects(frame)) }
        }
        prompt.update([])
    }
}
