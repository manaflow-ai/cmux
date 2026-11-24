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

    /// + › Screen Sharing names the workspace's Mac: the hub's Mac name matches it with
    /// case, spacing and a typographic apostrophe folded.
    @Test func aWorkspaceMacNameMatchesTheHubsName() {
        #expect(ScreenSharingPage.normalized("Aziz\u{2019}s MacBook Pro ") == ScreenSharingPage.normalized("aziz's macbook pro"))
        #expect(ScreenSharingPage.normalized("  ") == nil)
        #expect(ScreenSharingPage.normalized(nil) == nil)
    }

    @Test func aPendingRequestWaitsForTheMacThenItsTicketStartsTheStream() throws {
        let (service, ends) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        viewer.requestAnswered(.success(HubSession(id: "s1", state: .pending, scope: .full)), scope: .full)
        #expect(viewer.phase == .waitingForApproval(sessionID: "s1", scope: .full))
        #expect(viewer.screen == nil)

        service.route(.sessionTicket(ticket("s1", scope: .full)))
        #expect(viewer.phase == .streaming(sessionID: "s1", scope: .full))
        #expect(viewer.screen != nil)
        // The signaling goes to the stream once; a reconnect obtains a fresh ticket.
        #expect(viewer.takeSignaling() != nil)
        #expect(viewer.takeSignaling() == nil)
        #expect(viewer.screen?.reconnectLimit == 0)
        #expect(ends.calls.isEmpty)
    }

    /// A screen link (`cmux://mac-screen?device=…&display=…`) streams over `cmux.rd/1` on its
    /// display, never WebRTC (the joined Mac's share host refuses WebRTC offers): view only
    /// unless the link asked for control and the Mac granted it. The host's end or refusal
    /// ends the session; a link that failed reattaches like a dropped stream.
    @Test func aScreenLinkStreamsOverRdOnItsDisplayViewOnlyUnlessControlIsGranted() async throws {
        let (service, ends) = makeService()
        service.demoDiscovery = .listed
        service.demoMacs = [mac()]
        service.open(deviceID: hostID.uppercased(), name: nil, scope: .view, display: "69733382")
        let viewer = try #require(service.viewer)
        #expect(viewer.rd == MacScreenRdTarget(displayID: 69_733_382, control: false))
        viewer.requestAnswered(.success(HubSession(id: "s1", state: .pending, scope: .view)), scope: .view)
        service.route(.sessionTicket(ticket("s1", scope: .view)))
        #expect(viewer.phase == .streaming(sessionID: "s1", scope: .view))
        #expect(viewer.screen == nil, "no WebRTC session")
        #expect(viewer.rdScreen != nil)
        #expect(!viewer.rdControl)
        #expect(viewer.takeSignaling() == nil, "the ticket's signaling waits for the rd open")

        // A link failure reattaches; the host's refusal ends the session on the hub.
        viewer.rdClosed(sessionID: "s1", code: "link_failed", reason: "")
        #expect(viewer.phase == .reconnecting(sessionID: "s1", scope: .view))
        #expect(viewer.rdScreen != nil, "the picture stays for the reattach")
        service.route(.sessionTicket(ticket("s1", scope: .view)))
        #expect(viewer.phase == .streaming(sessionID: "s1", scope: .view))
        viewer.rdClosed(sessionID: "s1", code: "refused", reason: "sharing is off")
        #expect(viewer.phase == .ended(reason: "sharing is off"))
        #expect(viewer.rdScreen == nil)
        await ends.wait(for: 1)
        #expect(ends.calls == [Ends.Call(session: "s1", reason: "failed")])

        // Control asked: granted only with a full-scope ticket. A list tap after it is WebRTC.
        let (full, _) = makeService()
        full.demoDiscovery = .listed
        full.demoMacs = [mac()]
        full.open(deviceID: hostID, name: nil, scope: .full)
        let controller = try #require(full.viewer)
        #expect(controller.rd == MacScreenRdTarget(displayID: nil, control: true))
        controller.requestAnswered(.success(HubSession(id: "s2", state: .pending, scope: .full)), scope: .full)
        full.route(.sessionTicket(ticket("s2", scope: .full)))
        #expect(controller.rdControl)
        #expect(controller.screen == nil)
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

    @Test func aDroppedStreamReattachesWithTheRoamingBackoffAndKeepsTheScreenView() async throws {
        let (service, ends) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        viewer.requestAnswered(.success(HubSession(id: "s7", state: .approved, scope: .full)), scope: .full)
        service.route(.sessionTicket(ticket("s7", scope: .full)))
        let screen = try #require(viewer.screen)
        let reattach = Reattachments()
        viewer.reattachSession = { _, id in
            await reattach.record(id)
            return self.ticket(id, scope: .full)
        }
        let droppedAt = ContinuousClock.now
        viewer.streamDropped("s7")
        #expect(viewer.phase == .reconnecting(sessionID: "s7", scope: .full))
        #expect(viewer.screen === screen)
        let id = await reattach.wait()
        #expect(id == "s7")
        // The first try goes at once: the drop is already known (conn-quiet, 2026-11-14).
        #expect(ContinuousClock.now - droppedAt < .milliseconds(500))
        #expect(viewer.phase == .streaming(sessionID: "s7", scope: .full))
        #expect(viewer.screen === screen)
        #expect(ends.calls.isEmpty)
    }

    /// ask-a85f219369 (Leo: "i cant connect from [one Mac] to [another]"): an approved session whose
    /// ticket push never came (pushes have no backlog) asks the hub for the ticket and streams,
    /// instead of saying Connecting forever.
    @Test func anApprovedSessionWithNoTicketPushAsksTheHubForIt() async throws {
        let (service, _) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        viewer.ticketWait = .milliseconds(10)
        let reattach = Reattachments()
        viewer.reattachSession = { _, id in
            await reattach.record(id)
            return self.ticket(id, scope: .full)
        }
        viewer.requestAnswered(.success(HubSession(id: "s9", state: .approved, scope: .full)), scope: .full)
        #expect(viewer.phase == .approved(sessionID: "s9", scope: .full))
        let id = await reattach.wait()
        #expect(id == "s9")
        for _ in 0..<500 where viewer.phase != .streaming(sessionID: "s9", scope: .full) { await Task.yield() }
        #expect(viewer.phase == .streaming(sessionID: "s9", scope: .full))
        #expect(viewer.screen != nil)
    }

    /// The hub has no ticket either (the Mac went offline): the screen says why and ends the session.
    @Test func anApprovedSessionTheHubCannotAdmitSaysWhy() async throws {
        let (service, ends) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .view))
        viewer.ticketWait = .milliseconds(10)
        viewer.reattachSession = { _, _ in
            throw DeviceHubError.server(status: 409, code: .hostOffline, message: "the host is not connected")
        }
        viewer.requestAnswered(.success(HubSession(id: "s10", state: .approved, scope: .view)), scope: .view)
        for _ in 0..<2000 where viewer.phase == .approved(sessionID: "s10", scope: .view) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(viewer.phase == .refused(.hostOffline,
                                         requested: .view))
        for _ in 0..<500 where ends.calls.isEmpty { await Task.yield() }
        #expect(ends.calls == [Ends.Call(session: "s10", reason: "failed")])
    }

    /// conn-quiet (Leo, 2026-11-14: "shut the f*** up"): a dropped stream reattaches over its
    /// last frame with no card, no failed flash and no layout jump until the notice bound.
    @Test func aDroppedStreamSaysNothingUnderTheNoticeBoundAndKeepsItsLayout() throws {
        let (service, _) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        viewer.requestAnswered(.success(HubSession(id: "s8", state: .approved, scope: .full)), scope: .full)
        service.route(.sessionTicket(ticket("s8", scope: .full)))
        let screen = try #require(viewer.screen)
        viewer.reattachSession = { _, _ in throw CancellationError() }
        // The session's own give-up path hands the drop to the viewer at once.
        let dropped = try #require(screen.onDropped)
        #expect(dropped(), "the viewer takes the drop")
        #expect(viewer.phase == .reconnecting(sessionID: "s8", scope: .full))
        #expect(screen.phase == .connecting)
        #expect(screen.isReconnecting)
        #expect(!screen.reconnectNoticeDue)
        #expect(screen.keepsLiveLayout)
        #expect(ScreenSession.reconnectNoticeDelay == .seconds(10))
        viewer.close(reason: .viewerDisconnected)
    }

    /// Drop to the hub's reattach call, 8 drops in a row: the timing the conn-quiet table quotes
    /// (`drop_to_reattach_ms p50/p95`). Builds at base too, where every drop waited 1 s.
    @Test func dropToReattachIsUnder250MillisecondsAtP95() async throws {
        var samples: [Double] = []
        // One drop per viewer: each is the first drop of a stream (a stream that came up and
        // dropped starts its backoff over; the tests' streams never come up on their own).
        for _ in 0 ..< 8 {
            let (service, _) = makeService()
            let viewer = try #require(service.connect(to: mac(), scope: .full))
            viewer.requestAnswered(.success(HubSession(id: "s9", state: .approved, scope: .full)), scope: .full)
            service.route(.sessionTicket(ticket("s9", scope: .full)))
            let reattach = Reattachments()
            viewer.reattachSession = { _, id in
                await reattach.record(id)
                return self.ticket(id, scope: .full)
            }
            let droppedAt = ContinuousClock.now
            viewer.streamDropped("s9")
            _ = await reattach.wait()
            let elapsed = ContinuousClock.now - droppedAt
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            viewer.close(reason: .viewerDisconnected)
        }
        samples.sort()
        let p50 = samples[samples.count / 2], p95 = samples[samples.count - 1]
        print("conn-quiet drop_to_reattach_ms p50=\(Int(p50)) p95=\(Int(p95)) n=\(samples.count)")
        #expect(p95 < 250)
    }

    /// A stream that drops again before it ever came up does not ask the hub again at once,
    /// over and over: the second drop waits the backoff's next step.
    @Test func aStreamThatNeverComesUpBacksOffInsteadOfLooping() async throws {
        let (service, _) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        viewer.requestAnswered(.success(HubSession(id: "s11", state: .approved, scope: .full)), scope: .full)
        service.route(.sessionTicket(ticket("s11", scope: .full)))
        let reattach = Reattachments()
        viewer.reattachSession = { _, id in
            await reattach.record(id)
            return self.ticket(id, scope: .full)
        }
        viewer.streamDropped("s11")
        _ = await reattach.wait()
        for _ in 0 ..< 200 where viewer.phase != .streaming(sessionID: "s11", scope: .full) { await Task.yield() }
        let droppedAgainAt = ContinuousClock.now
        viewer.streamDropped("s11")
        _ = await reattach.wait()
        #expect(ContinuousClock.now - droppedAgainAt >= .seconds(1))
        viewer.close(reason: .viewerDisconnected)
    }

    /// Back in the foreground while a reattach sleeps out a long backoff step: it tries now.
    @Test func comingBackToTheForegroundReattachesNow() async throws {
        let (service, _) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        viewer.requestAnswered(.success(HubSession(id: "s10", state: .approved, scope: .full)), scope: .full)
        service.route(.sessionTicket(ticket("s10", scope: .full)))
        let calls = Reattachments()
        let failures = FailureBudget(2)
        viewer.reattachSession = { _, id in
            await calls.record(id)
            if failures.take() {
                throw CancellationError()
            }
            return self.ticket(id, scope: .full)
        }
        viewer.streamDropped("s10")
        _ = await calls.wait() // at once, fails
        _ = await calls.wait() // after 1 s, fails; the next step is 2 s
        let resumedAt = ContinuousClock.now
        viewer.reattachNow()
        _ = await calls.wait()
        #expect(ContinuousClock.now - resumedAt < .milliseconds(500))
        for _ in 0 ..< 200 where viewer.phase != .streaming(sessionID: "s10", scope: .full) { await Task.yield() }
        viewer.close(reason: .viewerDisconnected)
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
        #expect(viewer.phase == .refused(.other(reason: "offline"), requested: .full))
        // A code this build has no card for keeps the hub's words.
        viewer.request(.full)
        viewer.requestAnswered(.failure(.server(status: 429, code: .rateLimited, message: "too many requests; wait a minute")), scope: .full)
        #expect(viewer.phase == .refused(.other(reason: "too many requests; wait a minute"), requested: .full))
    }

    @Test func anUnknownRefusalKeepsTheHubsReason() {
        #expect(ScreenSharingRefusal(.server(status: 403, code: .other("new_code"), message: " ")) == .other(reason: "new_code"))
        #expect(ScreenSharingRefusal(.http(status: 502)) == .other(reason: "HTTP 502"))
        #expect(ScreenSharingRefusal(.transport("")) == .other(reason: nil))
        #expect(ScreenSharingRefusal(.server(status: 409, code: .hostOffline, message: "the host is not connected")) == .hostOffline)
        #expect(ScreenSharingRefusal.other(reason: "x").isOther && !ScreenSharingRefusal.notShared.isOther)
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

    func makeService(accountID: String? = nil) -> (ScreenSharingService, Ends) {
        let identity = DeviceIdentity(deviceID: UUID(), keys: TestKeys())
        let client = DeviceHubClient(baseURL: URL(string: "https://hub.invalid")!, identity: identity,
                                     tokens: DeviceHubAccountToken { "token" })
        let hub = DeviceHub(client: client, secrets: MemoryRelaySecretStore(), deviceName: "iPhone", platform: .ios)
        let configuration = ScreenSharingService.Configuration(baseURL: URL(string: "https://hub.invalid")!, bundleIdentifier: "test",
                                                               deviceName: "iPhone", tokens: DeviceHubAccountToken { "token" },
                                                               accountID: accountID)
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

@MainActor final class Reattachments {
    private var ids: [String] = []
    private var waiters: [CheckedContinuation<String, Never>] = []

    func record(_ id: String) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: id)
        } else {
            ids.append(id)
        }
    }

    func wait() async -> String {
        if !ids.isEmpty { return ids.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// How many more reattach calls fail.
@MainActor final class FailureBudget {
    private var left: Int
    init(_ left: Int) { self.left = left }
    func take() -> Bool {
        guard left > 0 else { return false }
        left -= 1
        return true
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

#if os(iOS)
/// A Mac that can't be shared says why in the list's alert, never as a full-screen card over
/// the list (user 2026-11-13).
extension ScreenSharingViewerTests {
    @Test func tappingAMacThatIsNotSharedShowsTheAlertAndAsksTheHubNothing() {
        let (service, ends) = makeService()
        let notShared = HubDevice(id: hostID, name: "Studio", platform: .macos, signingKey: "", macScreenShared: false, online: true)
        service.select(notShared)
        #expect(service.viewer == nil)
        #expect(service.alert?.refusal == .notShared)
        #expect(service.alert?.hostName == "Studio")
        #expect(ends.calls.isEmpty)
    }

    @Test func aRefusalBeforeTheViewerShowsBecomesTheAlert() throws {
        let (service, _) = makeService()
        service.select(mac(), scope: .full)
        let viewer = try #require(service.viewer)
        // Still asking the hub: nothing full screen, the row spins.
        #expect(service.viewerOnScreen == nil)
        // The list was stale: the hub says the Mac isn't sharing.
        viewer.requestAnswered(.failure(.server(status: 409, code: .notShared, message: "")), scope: .full)
        #expect(service.viewer == nil)
        #expect(service.viewerOnScreen == nil)
        let alert = try #require(service.alert)
        #expect(alert.hostID == hostID && alert.hostName == "Studio")
        #expect(alert.refusal == .notShared && alert.requested == .full)
    }

    @Test func onceShownARefusalStaysOnTheViewersCard() throws {
        let (service, _) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        viewer.requestAnswered(.success(HubSession(id: "s1", state: .pending, scope: .full)), scope: .full)
        #expect(service.viewerOnScreen === viewer)
        // Try Again on the card, refused: the card says why; no alert pulls it away.
        viewer.request(.full)
        #expect(service.viewerOnScreen === viewer)
        viewer.requestAnswered(.failure(.server(status: 409, code: .notShared, message: "")), scope: .full)
        #expect(service.viewerOnScreen === viewer)
        #expect(viewer.phase == .refused(.notShared, requested: .full))
        #expect(service.alert == nil)
    }

    @Test func leavingThePageEndsARequestThatNeverShowed() throws {
        let (service, _) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        service.leaveUnshownRequest()
        #expect(service.viewer == nil)
        #expect(viewer.phase == .ended(reason: ScreenSharingEndReason.viewerDisconnected.rawValue))
    }

    @Test func leavingThePageKeepsAViewerOnScreen() throws {
        let (service, _) = makeService()
        let viewer = try #require(service.connect(to: mac(), scope: .full))
        viewer.requestAnswered(.success(HubSession(id: "s1", state: .pending, scope: .full)), scope: .full)
        service.leaveUnshownRequest()
        #expect(service.viewer === viewer)
    }
}
#endif

#if os(iOS)
extension ScreenSharingViewerTests {
    /// Review: a request still waiting when an unavailable Mac is tapped would go full screen
    /// under that Mac's alert.
    @Test func tappingAnUnavailableMacEndsARequestStillWaiting() throws {
        let (service, _) = makeService()
        service.select(mac(), scope: .full)
        let waiting = try #require(service.viewer)
        let offline = HubDevice(id: "other-mac", name: "Office iMac", platform: .macos, signingKey: "", macScreenShared: true, online: false)
        service.select(offline)
        #expect(service.viewer == nil)
        #expect(service.alert?.refusal == .hostOffline)
        // The hub's late answer doesn't bring the old request on screen.
        waiting.requestAnswered(.success(HubSession(id: "s3", state: .pending, scope: .full)), scope: .full)
        #expect(service.viewerOnScreen == nil)
    }

}
#endif
