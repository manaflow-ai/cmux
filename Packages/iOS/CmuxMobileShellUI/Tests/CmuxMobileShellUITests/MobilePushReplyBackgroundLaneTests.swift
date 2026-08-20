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
    private var storedScheduled: [(delay: TimeInterval, text: String)] = []
    private var storedDeliveredNow: [String] = []
    private var storedCancelCount = 0

    var scheduled: [(delay: TimeInterval, text: String)] { lock.withLock { storedScheduled } }
    var deliveredNow: [String] { lock.withLock { storedDeliveredNow } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }

    func schedule(after delay: TimeInterval, replyText: String) async {
        lock.withLock { storedScheduled.append((delay: delay, text: replyText)) }
    }

    func deliverNow(replyText: String) async {
        lock.withLock { storedDeliveredNow.append(replyText) }
    }

    func cancel() async {
        lock.withLock { storedCancelCount += 1 }
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

@MainActor
private func makeReplyLaneCoordinator(
    runtime: ReplyRuntimeFake,
    notifier: ReplyNoticeFake,
    nowBox: NowBox
) -> MobilePushCoordinator {
    MobilePushCoordinator(
        registration: ReplyLanePushRegistration(),
        now: { nowBox.now },
        backgroundRuntime: runtime,
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
    #expect(notifier.scheduled.first?.text == "looks good, merge it")
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

    // One assertion spans both replies; the newer reply replaces the notice.
    #expect(runtime.beginCount == 1)
    #expect(runtime.endCount == 0)
    #expect(notifier.scheduled.map(\.text) == ["first", "second"])
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
