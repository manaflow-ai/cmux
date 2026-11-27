import Foundation

/// One-shot acknowledgement used by focus promotion to wait until the
/// foreground event listener exists locally and its server registration has
/// been acknowledged.
actor MobileTerminalEventSubscriptionReadiness {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func wait() async -> Bool {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resolve(_ value: Bool) {
        guard result == nil else { return }
        result = value
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume(returning: value)
        }
    }

    func hasSucceeded() -> Bool {
        result == true
    }
}
