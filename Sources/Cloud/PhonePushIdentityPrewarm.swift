/// Owns the off-main identity warm-up and the bounded dismissal handoff that
/// can occur while the process-stable snapshot is still being resolved.
@MainActor
final class PhonePushIdentityPrewarm {
    typealias ReadyHandler = @MainActor @Sendable () -> Void

    private static let maximumPendingIDs = 256
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
        task = Task { @MainActor [weak self] in
            await self?.identityProvider.prewarm()
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            onReady()
        }
    }

    func appendDismissals(ids: [String], badgeCount: Int) {
        pendingIDs.append(contentsOf: ids)
        let overflow = pendingIDs.count - Self.maximumPendingIDs
        if overflow > 0 {
            pendingIDs.removeFirst(overflow)
        }
        pendingBadgeCount = badgeCount
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
