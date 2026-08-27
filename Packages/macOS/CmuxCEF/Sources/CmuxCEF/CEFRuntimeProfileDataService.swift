public import Foundation
internal import CmuxCEFShim

/// Removes a named CEF profile directory only after the process-local request
/// context registry confirms that no live browser uses it.
@MainActor
public final class CEFRuntimeProfileDataService {
    private let runtimeIsInitialized: () -> Bool
    private let profileCacheIsIdle: (String) -> Bool
    private let deletionWorker: CEFRuntimeProfileDataDeletionWorker

    /// Creates a profile-data service using the live CEF registry.
    ///
    /// - Parameter fileManager: Filesystem dependency used for deletion.
    public convenience init(fileManager: FileManager = .default) {
        self.init(
            fileManager: fileManager,
            runtimeIsInitialized: { CEFRuntime.isInitialized },
            profileCacheIsIdle: { cmux_cef_profile_cache_is_idle($0) != 0 }
        )
    }

    /// Creates a profile-data service with deterministic test seams.
    ///
    /// This initializer remains module-internal so production callers use the
    /// live registry while package tests can model runtime state safely.
    init(
        fileManager: FileManager,
        runtimeIsInitialized: @escaping () -> Bool,
        profileCacheIsIdle: @escaping (String) -> Bool
    ) {
        self.runtimeIsInitialized = runtimeIsInitialized
        self.profileCacheIsIdle = profileCacheIsIdle
        deletionWorker = CEFRuntimeProfileDataDeletionWorker(
            fileManager: CEFRuntimeSendableFileManager(value: fileManager)
        )
    }

    /// Removes `cachePath` when it is safe to do so in the current process.
    ///
    /// The idle check runs synchronously on the CEF UI thread. Once the check
    /// succeeds, recursive removal is awaited on a serialized utility worker
    /// so filesystem latency never blocks the main actor. The shared CEF root
    /// is never removed by this API.
    ///
    /// - Parameter cachePath: A named profile cache path below CEF's root.
    /// - Returns: `true` when the path was removed or did not exist; `false`
    ///   when a live request context still owns it.
    @discardableResult
    public func removeIfIdle(at cachePath: String) async -> Bool {
        guard !runtimeIsInitialized() || profileCacheIsIdle(cachePath) else {
            return false
        }
        let worker = deletionWorker
        // The task is awaited before this lifecycle operation returns, so the
        // utility-priority filesystem work remains bounded by the caller and
        // cannot outlive the profile-deletion request as an unowned task.
        return await Task.detached(priority: .utility) {
            await worker.removeIfExists(atPath: cachePath)
        }.value
    }
}
