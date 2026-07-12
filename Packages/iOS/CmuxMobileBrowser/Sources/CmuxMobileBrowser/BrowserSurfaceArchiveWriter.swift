import Foundation

/// Delivers immutable browser archive I/O away from the main actor in request order.
// UserDefaults is documented thread-safe; every archive request is delivered to one serial queue.
final class BrowserSurfaceArchiveWriter: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let queue = DispatchQueue(
        label: "com.cmux.mobile.browser-archive",
        qos: .utility
    )

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func enqueueWrite(
        scope: BrowserPersistenceScope,
        snapshotsByWorkspace: [String: BrowserSurfaceSnapshot]
    ) {
        queue.async { [self] in
            write(scope: scope, snapshotsByWorkspace: snapshotsByWorkspace)
        }
    }

    func enqueueRemoval() {
        queue.async { [self] in
            defaults.removeObject(forKey: key)
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    private func write(
        scope: BrowserPersistenceScope,
        snapshotsByWorkspace: [String: BrowserSurfaceSnapshot]
    ) {
        let snapshots = snapshotsByWorkspace.keys.sorted().compactMap {
            snapshotsByWorkspace[$0]
        }
        let archive = BrowserSurfaceArchive(scope: scope, surfaces: snapshots)
        guard let data = try? JSONEncoder().encode(archive) else { return }
        defaults.set(data, forKey: key)
    }
}
