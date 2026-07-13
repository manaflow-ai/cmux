import Foundation

/// Delivers immutable browser archive I/O away from the main actor while
/// coalescing queued requests to the newest complete state.
// UserDefaults is documented thread-safe; one serial drain executes at a time.
final class BrowserSurfaceArchiveWriter: @unchecked Sendable {
    private enum Request {
        case write(
            scope: BrowserPersistenceScope,
            snapshotsByWorkspace: [String: BrowserSurfaceSnapshot],
            generation: String
        )
        case removal
    }

    private let defaults: UserDefaults
    private let key: String
    private let generationKey: String
    private let legacyMigrationKey: String
    private let requestLock = NSLock()
    private var pendingRequest: Request?
    private var isDrainScheduled = false
    private let queue = DispatchQueue(
        label: "com.cmux.mobile.browser-archive",
        qos: .utility
    )

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
        self.generationKey = "\(key).generation"
        self.legacyMigrationKey = "\(key).generation.legacyMigration"
    }

    func enqueueWrite(
        scope: BrowserPersistenceScope,
        snapshotsByWorkspace: [String: BrowserSurfaceSnapshot],
        generation: String
    ) {
        enqueue(.write(
            scope: scope,
            snapshotsByWorkspace: snapshotsByWorkspace,
            generation: generation
        ))
    }

    func enqueueRemoval() {
        enqueue(.removal)
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                drainPendingRequests()
                continuation.resume()
            }
        }
    }

    private func enqueue(_ request: Request) {
        let shouldSchedule = requestLock.withLock {
            pendingRequest = request
            guard !isDrainScheduled else { return false }
            isDrainScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        queue.async { [self] in
            drainPendingRequests()
        }
    }

    private func drainPendingRequests() {
        while let request = takePendingRequest() {
            switch request {
            case let .write(scope, snapshotsByWorkspace, generation):
                write(
                    scope: scope,
                    snapshotsByWorkspace: snapshotsByWorkspace,
                    generation: generation
                )
            case .removal:
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func takePendingRequest() -> Request? {
        requestLock.withLock {
            guard let pendingRequest else {
                isDrainScheduled = false
                return nil
            }
            self.pendingRequest = nil
            return pendingRequest
        }
    }

    private func write(
        scope: BrowserPersistenceScope,
        snapshotsByWorkspace: [String: BrowserSurfaceSnapshot],
        generation: String
    ) {
        let snapshots = snapshotsByWorkspace.keys.sorted().compactMap {
            snapshotsByWorkspace[$0]
        }
        let archive = BrowserSurfaceArchive(
            scope: scope,
            surfaces: snapshots,
            generation: generation
        )
        guard let data = try? JSONEncoder().encode(archive) else { return }
        defaults.set(data, forKey: key)
        if defaults.string(forKey: generationKey) == generation,
           defaults.string(forKey: legacyMigrationKey) == generation {
            defaults.removeObject(forKey: legacyMigrationKey)
        }
    }
}
