import Foundation

/// The last fleet page any Cloud surface read in this account session. The New
/// Machine sheet presents from it at once and refreshes in the background, so a
/// Cmd+N after the Machines panel has polled never waits for `GET /api/vm`.
/// Cleared at sign-out with every other account-scoped Cloud fact.
@MainActor
final class CloudFleetPageCache {
    static let shared = CloudFleetPageCache()

    private(set) var lastPage: VMListPage?
    private var accessObserver: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        accessObserver = notificationCenter.addObserver(
            forName: .cmuxCloudVMAccessDidEnd, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastPage = nil }
        }
    }

    deinit {
        if let accessObserver { NotificationCenter.default.removeObserver(accessObserver) }
    }

    func record(_ page: VMListPage) {
        lastPage = page
    }

    func clear() {
        lastPage = nil
    }
}
