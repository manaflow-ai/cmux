/// Owns the off-main identity warm-up and the bounded dismissal handoff that
/// can occur while the process-stable snapshot is still being resolved.
@MainActor
final class PhonePushIdentityPrewarm {
    typealias ReadyHandler = @MainActor @Sendable () -> Void

    private static let maximumPendingIDs =
        PhonePushSerialDeliveryQueue.defaultCapacity * 4
    private let identityProvider: any PhonePushIdentityProvider
    private var task: Task<Void, Never>?
    private var pendingIDs: [String] = []
    private var pendingBadgeCount = 0

    init(identityProvider: any PhonePushIdentityProvider = DefaultPhonePushIdentityProvider()) {
        self.identityProvider = identityProvider
    }

    func reset() {
        task?.cancel()
        task = nil
        pendingIDs.removeAll(keepingCapacity: true)
        pendingBadgeCount = 0
    }

    func start(onReady: @escaping ReadyHandler) {
        guard task == nil else { return }
        // The provider's once-initialization is finite and cancellation cannot
        // interrupt synchronous Foundation file operations. Keep this task
        // alive until readiness so every accepted dismissal can be flushed;
        // overflow is reported as queueFull rather than silently evicted.
        task = Task { @MainActor [weak self] in
            await self?.identityProvider.prewarm()
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            onReady()
        }
    }

    @discardableResult
    func appendDismissals(ids: [String], badgeCount: Int) -> Bool {
        guard pendingIDs.count + ids.count <= Self.maximumPendingIDs else {
            return false
        }
        pendingIDs.append(contentsOf: ids)
        pendingBadgeCount = badgeCount
        return true
    }

    func takePendingDismissals() -> (ids: [String], badgeCount: Int)? {
        guard !pendingIDs.isEmpty else { return nil }
        let result = (pendingIDs, pendingBadgeCount)
        pendingIDs.removeAll(keepingCapacity: true)
        pendingBadgeCount = 0
        return result
    }

    func deviceIDIfReady() -> String? {
        identityProvider.deviceIDIfReady()
    }
}

extension PhonePushClient {
    func startIdentityPrewarmIfNeeded() {
        identityPrewarm.start { [weak self] in
            self?.flushPendingDismissals()
        }
    }

    func flushPendingDismissals() {
        guard identityPrewarm.deviceIDIfReady() != nil,
              let pending = identityPrewarm.takePendingDismissals() else { return }
        forwardDismissed(ids: pending.ids, badgeCount: pending.badgeCount)
    }
}
