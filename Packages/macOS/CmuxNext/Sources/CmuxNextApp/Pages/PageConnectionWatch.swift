import CmuxNextDaemon
import CmuxNextPages
import Foundation
import Observation

/// Tells a page when its owner link (the local daemon) goes up or down, on the page's
/// `cmux.page.connection` stream (the Settings lead's page pattern). Event driven: it re-arms an
/// observation of the store's connection state; it ends when the page goes away.
@MainActor
final class PageConnectionWatch {
    private weak var page: PageWebView?
    private weak var store: DaemonStore?

    init(page: PageWebView, store: DaemonStore) {
        self.page = page
        self.store = store
    }

    func start() {
        guard let page, let store else { return }
        page.setConnected(Self.isConnected(store.connectionState))
        withObservationTracking {
            _ = store.connectionState
        } onChange: { [self] in
            // task-owner: one hop per observed change, re-arms itself; ends with the page
            Task { @MainActor in self.start() }
        }
    }

    static func isConnected(_ state: DaemonConnectionState) -> Bool {
        if case .connected = state { return true }
        return false
    }
}
