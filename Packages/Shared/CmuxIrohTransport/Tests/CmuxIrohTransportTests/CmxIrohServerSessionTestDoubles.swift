import CMUXMobileCore
import Foundation
@testable import CmuxIrohTransport

actor ServerSessionManualClock: CmxIrohRelayClock {
    private var sleeper: CheckedContinuation<Void, Never>?
    private var sleepWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated func now() -> Date {
        Date(timeIntervalSince1970: 1_800_000_000)
    }

    func sleep(until _: Date) async throws {
        let waiters = sleepWaiters
        sleepWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { sleeper = $0 }
        } onCancel: {
            Task { await self.cancelSleep() }
        }
        try Task.checkCancellation()
    }

    func waitUntilSleeping() async {
        if sleeper != nil { return }
        await withCheckedContinuation { sleepWaiters.append($0) }
    }

    func fire() {
        sleeper?.resume()
        sleeper = nil
    }

    private func cancelSleep() {
        sleeper?.resume()
        sleeper = nil
    }
}

actor FixedAdmissionAuthorizer: CmxIrohAdmissionAuthorizing {
    private let authorization: CmxIrohAdmissionAuthorization
    private var observedCalls = 0

    init(authorization: CmxIrohAdmissionAuthorization) {
        self.authorization = authorization
    }

    func authorize(
        credential _: CmxIrohAdmissionCredential,
        authenticatedPeerID _: CmxIrohPeerIdentity
    ) -> CmxIrohAdmissionAuthorization {
        observedCalls += 1
        return authorization
    }

    func callCount() -> Int { observedCalls }
}
