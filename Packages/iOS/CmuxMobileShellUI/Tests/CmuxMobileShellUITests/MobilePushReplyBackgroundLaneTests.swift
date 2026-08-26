import CmuxAuthRuntime
import Foundation
import Testing

@testable import CmuxMobileShellUI

// The inline-reply background lane: while a reply is parked the coordinator
// must hold one background task assertion (so iOS does not suspend the wake
// before the redial and retry ladder run) and must have a failure notice
// pre-scheduled (so a reply that never sends is reported instead of silently
// dropped). Both resolve when the reply does.

@MainActor
private final class ReplyRuntimeFake: BackgroundReplyRuntimeAsserting {
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private(set) var expirationHandler: (@MainActor () -> Void)?

    nonisolated init() {}

    func begin(
        expirationHandler: @escaping @MainActor () -> Void
    ) -> BackgroundReplyRuntimeAssertion? {
        beginCount += 1
        self.expirationHandler = expirationHandler
        return BackgroundReplyRuntimeAssertion(rawValue: beginCount)
    }

    func end(_ assertion: BackgroundReplyRuntimeAssertion) {
        endCount += 1
    }
}

private final class ReplyNoticeFake: ReplyFailureNoticing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedScheduled: [(delay: TimeInterval, replyId: String)] = []
    private var storedDeliveredNow: [String] = []
    private var storedCancelled: [String] = []

    var scheduled: [(delay: TimeInterval, replyId: String)] { lock.withLock { storedScheduled } }
    var deliveredNow: [String] { lock.withLock { storedDeliveredNow } }
    var cancelled: [String] { lock.withLock { storedCancelled } }
    var cancelCount: Int { lock.withLock { storedCancelled.count } }

    func schedule(after delay: TimeInterval, replyId: String) async {
        lock.withLock { storedScheduled.append((delay: delay, replyId: replyId)) }
    }

    func deliverNow(replyId: String) async {
        lock.withLock { storedDeliveredNow.append(replyId) }
    }

    func cancel(replyId: String) async {
        lock.withLock { storedCancelled.append(replyId) }
    }
}

private actor ReplyLanePushRegistration: PushRegistering {
    var isEnabled: Bool { false }
    var snapshot: PushRegistrationSnapshot { .disabled }

    func snapshots() -> AsyncStream<PushRegistrationSnapshot> {
        AsyncStream { continuation in
            continuation.yield(.disabled)
            continuation.finish()
        }
    }

    func setEnabled(_ enabled: Bool) async {}
    func applyEnabledIntent(_ enabled: Bool, generation: UInt64) async {}
    func reconcileEnabledIntent(generation: UInt64) async {}
    func register(deviceToken: Data) async {}
    func deviceTokenRegistrationFailed() async {}
    func syncTokenIfPossible() async {}
    func unregisterFromServer() async {}
    func unregisterFromServer(accessToken: String?, refreshToken: String?) async {}
    func unregisterFromServer(
        accountID: String?,
        accessToken: String?,
        refreshToken: String?
    ) async {}
}

private final class NowBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedNow = Date(timeIntervalSince1970: 1_000_000)

    var now: Date { lock.withLock { storedNow } }

    func advance(by interval: TimeInterval) {
        lock.withLock { storedNow = storedNow.addingTimeInterval(interval) }
    }
}

private final class ReplyRelayFake: ReplyRelaying, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [Bool]
    private var storedRequests: [RelayedReply] = []

    var requests: [RelayedReply] { lock.withLock { storedRequests } }

    /// Scripted acceptance per call; the last outcome repeats.
    init(outcomes: [Bool]) {
        self.outcomes = outcomes
    }

    func relay(_ reply: RelayedReply) async -> Bool {
        lock.withLock {
            storedRequests.append(reply)
            if outcomes.count > 1 {
                return outcomes.removeFirst()
            }
            return outcomes.first ?? false
        }
    }
}

@MainActor
private func makeReplyLaneCoordinator(
    runtime: ReplyRuntimeFake,
    notifier: ReplyNoticeFake,
    nowBox: NowBox,
    relay: any ReplyRelaying = NoopReplyRelay(),
    replyRetrySleep: @escaping @Sendable (Duration) async throws -> Void = {
        try await ContinuousClock().sleep(for: $0)
    }
) -> MobilePushCoordinator {
    MobilePushCoordinator(
        registration: ReplyLanePushRegistration(),
        now: { nowBox.now },
        replyRetrySleep: replyRetrySleep,
        backgroundRuntime: runtime,
        replyRelay: relay,
        replyFailureNotifier: notifier
    )
}

@MainActor
@Test func parkedReplyHoldsAssertionAndSchedulesFailureNotice() async {
    let runtime = ReplyRuntimeFake()
    let notifier = ReplyNoticeFake()
    let coordinator = makeReplyLaneCoordinator(
        runtime: runtime,
        notifier: notifier,
        nowBox: NowBox()
    )

    // No store bound: the reply parks (the store-less background wake).
    await coordinator.handleReply(
        text: "looks good, merge it",
        workspaceId: "workspace-1",
        surfaceId: "surface-1",
        macDeviceId: "mac-1",
        retargetsToLiveSurfaceOwner: true
    )

    #expect(runtime.beginCount == 1)
    #expect(runtime.endCount == 0)
    #expect(notifier.scheduled.count == 1)
    #expect(notifier.scheduled.first.map { !$0.replyId.isEmpty } == true)
    // Past the reply lifetime, with slack for an in-flight final send.
    #expect((notifier.scheduled.first?.delay ?? 0) > 120)
    #expect(notifier.cancelCount == 0)
}

@MainActor
@Test func blankReplyNeitherHoldsAssertionNorSchedulesNotice() async {
    let runtime = ReplyRuntimeFake()
    let notifier = ReplyNoticeFake()
    let coordinator = makeReplyLaneCoordinator(
        runtime: runtime,
        notifier: notifier,
        nowBox: NowBox()
    )

    await coordinator.handleReply(
        text: "  \n",
        workspaceId: "workspace-1",
        surfaceId: "surface-1",
        macDeviceId: "mac-1",
        retargetsToLiveSurfaceOwner: true
    )

    #expect(runtime.beginCount == 0)
    #expect(notifier.scheduled.isEmpty)
}

@MainActor
@Test func replacementReplyReusesTheHeldAssertionAndReschedulesNotice() async {
    let runtime = ReplyRuntimeFake()
    let notifier = ReplyNoticeFake()
    let coordinator = makeReplyLaneCoordinator(
        runtime: runtime,
        notifier: notifier,
        nowBox: NowBox()
    )

    await coordinator.handleReply(
        text: "first",
        workspaceId: "workspace-1",
        surfaceId: "surface-1",
        macDeviceId: "mac-1",
        retargetsToLiveSurfaceOwner: true
    )
    await coordinator.handleReply(
        text: "second",
        workspaceId: "workspace-1",
        surfaceId: "surface-1",
        macDeviceId: "mac-1",
        retargetsToLiveSurfaceOwner: true
    )

    // One assertion spans both replies. Each reply schedules its own notice,
    // and parking the second cancels exactly the first's — generation-safe.
    #expect(runtime.beginCount == 1)
    #expect(runtime.endCount == 0)
    #expect(notifier.scheduled.count == 2)
    #expect(notifier.scheduled[0].replyId != notifier.scheduled[1].replyId)
    #expect(notifier.cancelled == [notifier.scheduled[0].replyId])
}

@MainActor
@Test func expiredReplyReleasesAssertionAndLeavesNoticeToFire() async throws {
    let runtime = ReplyRuntimeFake()
    let notifier = ReplyNoticeFake()
    let nowBox = NowBox()
    let coordinator = makeReplyLaneCoordinator(
        runtime: runtime,
        notifier: notifier,
        nowBox: nowBox
    )

    await coordinator.handleReply(
        text: "too late",
        workspaceId: "workspace-1",
        surfaceId: "surface-1",
        macDeviceId: "mac-1",
        retargetsToLiveSurfaceOwner: true
    )
    #expect(runtime.beginCount == 1)

    nowBox.advance(by: PendingReplyState.lifetime + 1)
    coordinator.workspacesDidChange()

    var released = false
    for _ in 0..<300 {
        if runtime.endCount == 1 {
            released = true
            break
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(released, "an expired reply must release the background assertion")
    // The pre-scheduled notice is the expiry's user-visible report; it must
    // NOT be cancelled.
    #expect(notifier.cancelCount == 0)
}

@MainActor
@Test func relayAcceptanceConsumesTheReplyAndResolvesAssertionAndNotice() async {
    let runtime = ReplyRuntimeFake()
    let notifier = ReplyNoticeFake()
    let relay = ReplyRelayFake(outcomes: [true])
    let coordinator = makeReplyLaneCoordinator(
        runtime: runtime,
        notifier: notifier,
        nowBox: NowBox(),
        relay: relay
    )

    // No store bound (the store-less background wake): the reply relays.
    await coordinator.handleReply(
        text: "looks good, merge it",
        workspaceId: "workspace-1",
        surfaceId: "surface-1",
        macDeviceId: "mac-1",
        retargetsToLiveSurfaceOwner: true
    )

    #expect(relay.requests.count == 1)
    #expect(relay.requests.first?.macDeviceId == "mac-1")
    #expect(relay.requests.first?.surfaceId == "surface-1")
    #expect(relay.requests.first?.text == "looks good, merge it")
    #expect(relay.requests.first.map { !$0.replyId.isEmpty } == true)
    // Accepted: the reply is the server's now — assertion released, notice
    // cancelled, nothing left parked.
    #expect(runtime.endCount == 1)
    #expect(notifier.cancelCount == 1)
}

@MainActor
@Test func relayDeclineKeepsTheReplyParkedWithAssertionAndNotice() async {
    let runtime = ReplyRuntimeFake()
    let notifier = ReplyNoticeFake()
    let relay = ReplyRelayFake(outcomes: [false])
    let coordinator = makeReplyLaneCoordinator(
        runtime: runtime,
        notifier: notifier,
        nowBox: NowBox(),
        relay: relay
    )

    await coordinator.handleReply(
        text: "still here",
        workspaceId: "workspace-1",
        surfaceId: "surface-1",
        macDeviceId: "mac-1",
        retargetsToLiveSurfaceOwner: true
    )

    #expect(relay.requests.count == 1)
    #expect(runtime.endCount == 0)
    #expect(notifier.cancelCount == 0)
}

@MainActor
@Test func retryLadderRetriesTheRelayWithTheSameReplyId() async throws {
    let runtime = ReplyRuntimeFake()
    let notifier = ReplyNoticeFake()
    let relay = ReplyRelayFake(outcomes: [false, true])
    let coordinator = makeReplyLaneCoordinator(
        runtime: runtime,
        notifier: notifier,
        nowBox: NowBox(),
        relay: relay,
        replyRetrySleep: { _ in }
    )

    await coordinator.handleReply(
        text: "retry me",
        workspaceId: "workspace-1",
        surfaceId: "surface-1",
        macDeviceId: "mac-1",
        retargetsToLiveSurfaceOwner: true
    )

    var resolved = false
    for _ in 0..<300 {
        if runtime.endCount == 1 {
            resolved = true
            break
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(resolved, "the ladder must retry the relay until acceptance")
    #expect(relay.requests.count == 2)
    // Idempotency across retries: the server dedupes on replyId.
    #expect(relay.requests.first?.replyId == relay.requests.last?.replyId)
    #expect(notifier.cancelCount == 1)
}

@MainActor
@Test func replyWithoutMacClaimStaysParkedWithoutRelayCall() async {
    let runtime = ReplyRuntimeFake()
    let notifier = ReplyNoticeFake()
    let relay = ReplyRelayFake(outcomes: [true])
    let coordinator = makeReplyLaneCoordinator(
        runtime: runtime,
        notifier: notifier,
        nowBox: NowBox(),
        relay: relay
    )

    // An old-Mac push without a mac claim: the inbox cannot route it (and
    // that Mac cannot sweep it), so the reply waits for a late direct send.
    await coordinator.handleReply(
        text: "old mac",
        workspaceId: "workspace-1",
        surfaceId: "surface-1",
        macDeviceId: nil,
        retargetsToLiveSurfaceOwner: true
    )

    #expect(relay.requests.isEmpty)
    #expect(runtime.endCount == 0)
    #expect(notifier.cancelCount == 0)
}

@MainActor
@Test func systemExpirationReleasesTheAssertionWithoutDroppingTheReply() async {
    let runtime = ReplyRuntimeFake()
    let notifier = ReplyNoticeFake()
    let coordinator = makeReplyLaneCoordinator(
        runtime: runtime,
        notifier: notifier,
        nowBox: NowBox()
    )

    await coordinator.handleReply(
        text: "still pending",
        workspaceId: "workspace-1",
        surfaceId: "surface-1",
        macDeviceId: "mac-1",
        retargetsToLiveSurfaceOwner: true
    )
    #expect(runtime.beginCount == 1)

    // iOS is closing the window: the holder must release promptly, and the
    // reply must stay parked for a foreground within its lifetime.
    runtime.expirationHandler?()
    #expect(runtime.endCount == 1)
    #expect(notifier.cancelCount == 0)
}
