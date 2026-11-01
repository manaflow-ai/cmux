#if os(iOS)
import CmuxDeviceHub
import CmuxScreenKit
import CryptoKit
import Foundation
import Testing
@testable import CmuxMobileScreenSharing

/// The phone's side of a device hub session (PROTOCOL.md, Session flow): what
/// the viewer shows for each answer and push, and that every session it leaves
/// is ended on the hub.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ScreenSharingViewerTests {
    let hostID = "4f6b8a2c-1d3e-4b5a-8c7d-9e0f1a2b3c4d"

    @Test func aPendingRequestWaitsForTheMacThenItsTicketStartsTheStream() throws {
        let (service, ends) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        viewer.requestAnswered(.success(HubSession(id: "s1", state: .pending, scope: .full)), scope: .full)
        #expect(viewer.phase == .waitingForApproval(sessionID: "s1", scope: .full))
        #expect(viewer.screen == nil)

        service.route(.sessionTicket(ticket("s1", scope: .full)))
        #expect(viewer.phase == .streaming(sessionID: "s1", scope: .full))
        #expect(viewer.screen != nil)
        // The signaling goes to the stream once: a reconnect would need a new ticket.
        #expect(viewer.takeSignaling() != nil)
        #expect(viewer.takeSignaling() == nil)
        #expect(viewer.screen?.reconnectLimit == 0)
        #expect(ends.calls.isEmpty)
    }

    @Test func aTicketBeforeTheHTTPAnswerIsTakenAndTheAnswerChangesNothing() throws {
        let (service, _) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .view))
        service.route(.sessionTicket(ticket("s2", scope: .view)))
        #expect(viewer.phase == .streaming(sessionID: "s2", scope: .view))
        viewer.requestAnswered(.success(HubSession(id: "s2", state: .approved, scope: .view)), scope: .view)
        #expect(viewer.phase == .streaming(sessionID: "s2", scope: .view))
    }

    @Test func pushesForAnotherSessionOrRoleAreIgnored() throws {
        let (service, _) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        viewer.requestAnswered(.success(HubSession(id: "s3", state: .pending)), scope: .full)
        service.route(.sessionTicket(ticket("other", scope: .full)))
        service.route(.sessionTicket(ticket("s3", scope: .full, role: .host)))
        service.route(.sessionRevoked(sessionID: "other", reason: "host_stopped"))
        #expect(viewer.phase == .waitingForApproval(sessionID: "s3", scope: .full))
    }

    @Test func denialRevocationAndEndStopTheStreamAndSayWhy() throws {
        let (service, _) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        viewer.requestAnswered(.success(HubSession(id: "s4", state: .pending)), scope: .full)
        service.route(.sessionDenied(sessionID: "s4"))
        #expect(viewer.phase == .declined(.full))

        viewer.request(.full)
        viewer.requestAnswered(.success(HubSession(id: "s5", state: .approved, scope: .full)), scope: .full)
        service.route(.sessionTicket(ticket("s5", scope: .full)))
        #expect(viewer.screen != nil)
        service.route(.sessionRevoked(sessionID: "s5", reason: "sharing_off"))
        #expect(viewer.phase == .ended(reason: "sharing_off"))
        #expect(viewer.screen == nil)
    }

    @Test func closingEndsTheSessionOnTheHubWithTheViewersReason() async throws {
        let (service, ends) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        viewer.requestAnswered(.success(HubSession(id: "s6", state: .approved, scope: .full)), scope: .full)
        service.route(.sessionTicket(ticket("s6", scope: .full)))
        service.dismissViewer()
        #expect(service.viewer == nil)
        #expect(viewer.screen == nil)
        await ends.wait(for: 1)
        #expect(ends.calls == [Ends.Call(session: "s6", reason: "viewer_disconnected")])
    }

    @Test func aRequestCancelledBeforeItsAnswerEndsTheSessionItMadeEvenAfterTheViewerIsGone() async throws {
        let (service, ends) = makeService()
        weak var weakViewer = service.connect(to: mac(), scope: .full)
        // The request is out (its call waits for an answer) before the person cancels.
        await ends.waitForRequest()
        service.dismissViewer()
        #expect(service.viewer == nil)
        #expect(weakViewer == nil)
        ends.answer(HubSession(id: "late", state: .pending, scope: .full))
        await ends.wait(for: 1)
        #expect(ends.calls == [Ends.Call(session: "late", reason: "viewer_disconnected")])
    }

    @Test func aTicketForASessionTheViewerLeftNeverStartsTheNextRequest() async throws {
        let (service, ends) = makeService()
        let first = try #require(service.connect(to: mac(), scope: .full))
        first.requestAnswered(.success(HubSession(id: "old", state: .approved, scope: .full)), scope: .full)
        service.dismissViewer()
        await ends.wait(for: 1)
        let second = try #require(service.connect(to: mac(), scope: .full))
        // The old session's ticket arrives while the new request is out: ignored.
        service.route(.sessionTicket(ticket("old", scope: .full)))
        #expect(second.phase == .requesting(.full))
        #expect(second.screen == nil)
        second.requestAnswered(.success(HubSession(id: "new", state: .approved, scope: .full)), scope: .full)
        service.route(.sessionTicket(ticket("new", scope: .full)))
        #expect(second.phase == .streaming(sessionID: "new", scope: .full))
    }

    @Test func aDroppedStreamEndsTheHubSessionAndOffersToConnectAgain() async throws {
        let (service, ends) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        viewer.requestAnswered(.success(HubSession(id: "s7", state: .approved, scope: .full)), scope: .full)
        service.route(.sessionTicket(ticket("s7", scope: .full)))
        viewer.streamDropped("s7")
        #expect(viewer.phase == .ended(reason: "failed"))
        #expect(viewer.screen == nil)
        await ends.wait(for: 1)
        #expect(ends.calls == [Ends.Call(session: "s7", reason: "failed")])
        // The Mac's own reason, arriving after the drop, replaces "failed" on the card.
        service.route(.sessionRevoked(sessionID: "s7", reason: "sharing_off"))
        #expect(viewer.phase == .ended(reason: "sharing_off"))
        // A late drop of an older stream changes nothing.
        viewer.streamDropped("s0")
        #expect(viewer.phase == .ended(reason: "sharing_off"))
    }

    @Test func aFailedSignOutEndsTheSessionAndStopSignsOutAgain() async throws {
        let (service, ends) = makeService()
        let signOuts = SignOuts(failing: true)
        service.signOutDevice = { _ in try signOuts.call() }
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        viewer.requestAnswered(.success(HubSession(id: "s8", state: .approved, scope: .full)), scope: .full)
        service.route(.sessionTicket(ticket("s8", scope: .full)))
        await service.signOutBeforeSessionEnds()
        #expect(signOuts.count == 1)
        // The hub still has the session: the viewer ends it itself.
        #expect(viewer.phase == .ended(reason: "signed_out"))
        await ends.wait(for: 1)
        #expect(ends.calls == [Ends.Call(session: "s8", reason: "signed_out")])
        // The phone is not signed out of the hub yet, so stop() tries again.
        service.stop()
        await service.stopping?.value
        #expect(signOuts.count == 2)
        #expect(service.hub == nil)
    }

    @Test func aSignOutThatWorkedIsNotRepeatedByStop() async throws {
        let (service, ends) = makeService()
        let signOuts = SignOuts(failing: false)
        service.signOutDevice = { _ in try signOuts.call() }
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        viewer.requestAnswered(.success(HubSession(id: "s9", state: .approved, scope: .full)), scope: .full)
        service.route(.sessionTicket(ticket("s9", scope: .full)))
        await service.signOutBeforeSessionEnds()
        #expect(viewer.phase == .ended(reason: "signed_out"))
        service.stop()
        await service.stopping?.value
        #expect(signOuts.count == 1)
        // Signing out ended the session on the hub: no /end of its own.
        #expect(ends.calls.isEmpty)
    }

    @Test func aDenialPushedBeforeTheAnswerIsKeptForIt() throws {
        let (service, _) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .view))
        service.route(.sessionDenied(sessionID: "s8"))
        #expect(viewer.phase == .requesting(.view))
        viewer.requestAnswered(.success(HubSession(id: "s8", state: .pending, scope: .view)), scope: .view)
        #expect(viewer.phase == .declined(.view))
    }

    @Test func aRepeatedTicketKeepsTheRunningStream() throws {
        let (service, _) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        service.route(.sessionTicket(ticket("s9", scope: .full)))
        let screen = try #require(viewer.screen)
        service.route(.sessionTicket(ticket("s9", scope: .full)))
        #expect(viewer.screen === screen)
    }

    @Test func refusalsMapToTheirCards() throws {
        let (service, _) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        viewer.requestAnswered(.failure(.server(status: 403, code: .permissionNone, message: "")), scope: .full)
        #expect(viewer.phase == .refused(.permissionNone, requested: .full))
        viewer.request(.full)
        viewer.requestAnswered(.failure(.server(status: 409, code: .hostOffline, message: "")), scope: .full)
        #expect(viewer.phase == .refused(.hostOffline, requested: .full))
        viewer.request(.full)
        viewer.requestAnswered(.failure(.transport("offline")), scope: .full)
        #expect(viewer.phase == .refused(.other, requested: .full))
    }

    @Test func theListPutsSharedOnlineMacsFirstAndLeavesOutPhones() {
        let macs = [
            HubDevice(id: "a", name: "Zed", platform: .macos, macScreenShared: false, online: true),
            HubDevice(id: "b", name: "Studio", platform: .macos, macScreenShared: true, online: false),
            HubDevice(id: "c", name: "Mini", platform: .macos, macScreenShared: true, online: true),
            HubDevice(id: "d", name: "Phone", platform: .ios, online: true),
        ]
        let order = macs.filter { $0.platform == .macos }.sorted(by: ScreenSharingService.listOrder).map(\.name)
        #expect(order == ["Mini", "Zed", "Studio"])
    }

    @Test func preferencesKeepTheViewersChoicesForTheNextSession() {
        let store = UserDefaults(suiteName: "screen-sharing-tests-\(UUID().uuidString)")!
        let preferences = ScreenSharingPreferences(store: store)
        #expect(preferences.defaultScope == .full)
        var changed = preferences.screen(for: hostID)
        changed.quality = .smooth
        changed.showStats = false
        changed.inputMode = .trackpad
        preferences.save(changed, for: hostID)
        preferences.defaultScope = .view
        let reloaded = ScreenSharingPreferences(store: store)
        #expect(reloaded.screen(for: "another-mac").quality == .smooth)
        #expect(reloaded.screen(for: "another-mac").showStats == false)
        #expect(reloaded.screen(for: "another-mac").inputMode == .trackpad)
        #expect(reloaded.defaultScope == .view)
    }

    // MARK: Fixtures

    func makeService() -> (ScreenSharingService, Ends) {
        let identity = DeviceIdentity(deviceID: UUID(), keys: TestKeys())
        let client = DeviceHubClient(baseURL: URL(string: "https://hub.invalid")!, identity: identity,
                                     tokens: DeviceHubAccountToken { "token" })
        let hub = DeviceHub(client: client, secrets: MemoryRelaySecretStore(), deviceName: "iPhone", platform: .ios)
        let configuration = ScreenSharingService.Configuration(baseURL: URL(string: "https://hub.invalid")!, bundleIdentifier: "test",
                                                               deviceName: "iPhone", tokens: DeviceHubAccountToken { "token" })
        let service = ScreenSharingService(hub: hub, configuration: configuration,
                                           preferences: ScreenSharingPreferences(store: UserDefaults(suiteName: UUID().uuidString)!))
        let ends = Ends()
        service.prepareViewer = { viewer in
            viewer.makeSignaling = { _, _ in FakeSignaling() }
            viewer.startStream = { _ in }
            viewer.endSession = { _, id, reason in ends.record(id, reason) }
            // The HTTP answer never comes on its own: each test answers by hand
            // (`requestAnswered`), or delivers it late through `ends.answer`.
            viewer.requestSession = { _, _, _ in
                let (answers, continuation) = AsyncStream<HubSession>.makeStream()
                ends.hold(continuation)
                for await session in answers { return session }
                throw CancellationError()
            }
        }
        return (service, ends)
    }

    func mac() -> HubDevice {
        HubDevice(id: hostID, name: "Studio", platform: .macos, signingKey: "", macScreenShared: true, online: true)
    }

    func ticket(_ id: String, scope: SessionScope, role: SessionTicket.Role = .viewer) -> SessionTicket {
        SessionTicket(sessionId: id, ticket: "jws", signalURL: URL(string: "wss://hub.invalid/v1/sessions/\(id)/ws")!, ice: [],
                      peer: .init(id: hostID, name: "Studio", signingKey: ""), role: role, scope: scope)
    }
}

@MainActor final class Ends {
    struct Call: Equatable { var session: String; var reason: String }
    private(set) var calls: [Call] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    /// Open request answers (kept so their streams stay open until the request is cancelled).
    private var answers: [AsyncStream<HubSession>.Continuation] = []

    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func hold(_ answer: AsyncStream<HubSession>.Continuation) {
        answers.append(answer)
        let waiting = requestWaiters
        requestWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// Returns once a request's HTTP call is waiting for its answer.
    func waitForRequest() async {
        guard answers.isEmpty else { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    /// Delivers the HTTP answer to the oldest request still out, even one already cancelled.
    func answer(_ session: HubSession) {
        guard !answers.isEmpty else { return }
        let next = answers.removeFirst()
        next.yield(session)
        next.finish()
    }

    func record(_ session: String, _ reason: String) {
        calls.append(Call(session: session, reason: reason))
        let ready = waiters.filter { calls.count >= $0.0 }
        waiters.removeAll { calls.count >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
    }

    /// Returns once `count` ends were recorded (each `/end` runs in its own task).
    func wait(for count: Int) async {
        guard calls.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

/// The hub's sign-out call: counts its calls and fails each when `failing`.
@MainActor final class SignOuts {
    struct Offline: Error {}
    let failing: Bool
    private(set) var count = 0
    init(failing: Bool) { self.failing = failing }
    func call() throws {
        count += 1
        if failing { throw Offline() }
    }
}

final class FakeSignaling: ScreenSignaling, @unchecked Sendable {
    func messages() -> AsyncThrowingStream<ScreenSignal, any Error> { AsyncThrowingStream { _ in } }
    func send(_: ScreenSignal) async throws {}
    func iceServers() async throws -> [ICEServerConfig] { [] }
    func close() {}
    var endsSessionOnClose: Bool { true }
}

struct TestKeys: DeviceKeyMaterial {
    let signing = P256.Signing.PrivateKey()
    let agreement = P256.KeyAgreement.PrivateKey()
    var signingPublicKey: P256.Signing.PublicKey { signing.publicKey }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { agreement.publicKey }
    func signature(for message: Data) throws -> P256.Signing.ECDSASignature { try signing.signature(for: message) }
    func open(_: Data, encapsulatedKey _: Data, info _: Data) throws -> Data { Data() }
}

#endif
