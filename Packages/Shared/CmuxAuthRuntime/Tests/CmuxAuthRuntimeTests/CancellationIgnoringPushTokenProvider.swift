import Foundation
@testable import CmuxAuthRuntime

actor CancellationIgnoringPushTokenProvider: TokenProviding {
    private let snapshotValue = AuthenticatedSessionSnapshot(
        generation: 1,
        accountID: "push-user-1",
        accessToken: "access",
        refreshToken: "refresh"
    )
    private let started: TestPhaseSignal
    private let blocker: TestContinuationBlocker
    private let cancellationObserved = TestPhaseSignal()
    private let completed = TestPhaseSignal()
    private(set) var snapshotRequestCount = 0

    init(started: TestPhaseSignal, blocker: TestContinuationBlocker) {
        self.started = started
        self.blocker = blocker
    }

    func authenticatedSessionSnapshot() async throws
        -> AuthenticatedSessionSnapshot {
        snapshotRequestCount += 1
        await started.markStarted()
        let cancellationObserved = cancellationObserved
        return await withTaskCancellationHandler {
            await blocker.wait()
            await completed.markStarted()
            return snapshotValue
        } onCancel: {
            Task { await cancellationObserved.markStarted() }
        }
    }

    func waitUntilCancellationObserved() async {
        await cancellationObserved.waitUntilStarted()
    }

    func waitUntilCompleted() async {
        await completed.waitUntilStarted()
    }

    func isAuthenticatedSessionCurrent(
        _ snapshot: AuthenticatedSessionSnapshot
    ) async -> Bool {
        snapshot == snapshotValue
    }

    func accessToken() async throws -> String { snapshotValue.accessToken }
    func storedAccessToken() async -> String? { snapshotValue.accessToken }
    func refreshToken() async -> String? { snapshotValue.refreshToken }
    func forceRefreshAccessToken() async throws -> String {
        snapshotValue.accessToken
    }
}
