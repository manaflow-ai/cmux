import CmuxSettings
import Foundation

@testable import CmuxSettingsUI

@MainActor
final class AgentRecoverySettingsHostActionsSpy: SettingsHostActions {
    enum WaitError: Error, Sendable {
        case timedOut
    }

    private let autoRetryChangeStream: AsyncStream<Void>
    private let autoRetryChangeContinuation: AsyncStream<Void>.Continuation
    private(set) var autoRetryChangeCount = 0

    init() {
        let stream = AsyncStream<Void>.makeStream()
        autoRetryChangeStream = stream.stream
        autoRetryChangeContinuation = stream.continuation
    }

    deinit {
        autoRetryChangeContinuation.finish()
    }

    func agentSessionAutoRetrySettingDidChange() {
        autoRetryChangeCount += 1
        autoRetryChangeContinuation.yield(())
    }

    /// Waits for the commit callback, or fails after a bounded deadline.
    func waitForAutoRetryChange(timeout: Duration = .seconds(5)) async throws {
        guard autoRetryChangeCount == 0 else { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [autoRetryChangeStream] in
                var iterator = autoRetryChangeStream.makeAsyncIterator()
                _ = await iterator.next()
            }
            group.addTask {
                try await ContinuousClock().sleep(for: timeout)
                throw WaitError.timedOut
            }
            guard try await group.next() != nil else {
                throw WaitError.timedOut
            }
            group.cancelAll()
        }
    }

    func clearBrowserHistory() {}
    func openConfigInExternalEditor() {}
    func sendFeedback() {}
    func sendTestNotification() {}
    func openSystemNotificationSettings() {}
    func restartApp() {}
    func openBrowserImportFlow() {}
    func requestNotificationAuthorization() {}
    func openTerminalConfigWindow() {}
    func previewNotificationSound(value: String, customFilePath: String) {}
}
