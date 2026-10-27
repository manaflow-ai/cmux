import CmuxNextDaemon
import CmuxNextPages
import CmuxNextWakeups

/// Tells a page when its owner link (the local daemon) goes up or down, on the page's
/// `cmux.page.connection` stream (the Settings lead's page pattern). One `.automation` apply per
/// change (``FrameObservation``): a page in a hidden or occluded window acts on its connection too,
/// and the class needs no display link. The watch keeps itself until the first change after the
/// page went away, as the re-armed observation it replaces did.
@MainActor
final class PageConnectionWatch {
    private weak var page: PageWebView?
    private weak var store: DaemonStore?
    private let work: MainWorkScheduler
    private var observation: FrameObservation<Bool>?
    /// Connection states handed to the page (tests).
    private(set) var handOffs = 0

    init(page: PageWebView, store: DaemonStore, on work: MainWorkScheduler) {
        self.page = page
        self.store = store
        self.work = work
    }

    func start() {
        guard observation == nil, page != nil, let store else { return }
        let observation = FrameObservation(owner: "page.connection", delivery: .automation, on: work) { [weak store] in
            store.map { Self.isConnected($0.connectionState) } ?? false
        } onChange: { [self] connected in
            hand(connected)
        }
        self.observation = observation
        hand(observation.value)
    }

    private func hand(_ connected: Bool) {
        guard let page else {
            observation?.cancel()
            observation = nil
            return
        }
        handOffs += 1
        page.setConnected(connected)
    }

    static func isConnected(_ state: DaemonConnectionState) -> Bool {
        if case .connected = state { return true }
        return false
    }
}
