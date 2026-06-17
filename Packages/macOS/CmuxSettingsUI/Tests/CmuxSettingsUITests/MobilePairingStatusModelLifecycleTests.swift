import Testing

@testable import CmuxSettingsUI

/// Lifecycle regression tests for ``MobilePairingStatusModel``.
@MainActor
@Suite struct MobilePairingStatusModelLifecycleTests {
    @Test func initializationDoesNotReadHostStatusOrStartObservationStream() {
        let (stream, _) = AsyncStream<MobilePairingStatusSnapshot>.makeStream()
        let hostActions = CountingHostActions(stream: stream)

        _ = MobilePairingStatusModel(hostActions: hostActions)

        #expect(hostActions.statusReads == 0)
        #expect(hostActions.streamCreations == 0)
    }
}

@MainActor
private final class CountingHostActions: SettingsHostActions {
    var statusReads = 0
    var streamCreations = 0

    private let stream: AsyncStream<MobilePairingStatusSnapshot>

    init(stream: AsyncStream<MobilePairingStatusSnapshot>) {
        self.stream = stream
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

    func mobilePairingStatus() -> MobilePairingStatusSnapshot? {
        statusReads += 1
        return nil
    }

    func mobilePairingStatusUpdates() -> AsyncStream<MobilePairingStatusSnapshot> {
        streamCreations += 1
        return stream
    }
}
