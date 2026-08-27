public import Foundation
internal import CmuxCEFShim

/// Removes a named CEF profile directory only after the process-local request
/// context registry confirms that no live browser uses it.
@MainActor
public final class CEFRuntimeProfileDataService {
    private let fileManager: FileManager
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
        self.fileManager = fileManager
        self.runtimeIsInitialized = runtimeIsInitialized
        self.profileCacheIsIdle = profileCacheIsIdle
        deletionWorker = CEFRuntimeProfileDataDeletionWorker(
            fileManager: CEFRuntimeSendableFileManager(value: fileManager)
        )
    }

    /// Removes `cachePath` when it is safe to do so in the current process.
    ///
    /// The idle check and an atomic rename reservation run synchronously on the
    /// CEF UI thread. Once reserved, recursive removal targets the renamed
    /// tombstone on a serialized utility worker, so filesystem latency never
    /// blocks the main actor and a newly-created context cannot share the tree.
    /// The shared CEF root is never removed by this API.
    ///
    /// - Parameter cachePath: A named profile cache path below CEF's root.
    /// - Returns: `true` when the path was removed or did not exist; `false`
    ///   when a live request context still owns it.
    @discardableResult
    public func removeIfIdle(at cachePath: String) async -> Bool {
        let isRuntimeInitialized = runtimeIsInitialized()
        guard !isRuntimeInitialized || profileCacheIsIdle(cachePath) else {
            return false
        }
        let deletionPath = "\(cachePath).deleting-\(UUID().uuidString)"
        let reservation: Int32
        if isRuntimeInitialized {
            reservation = cmux_cef_profile_cache_prepare_for_deletion(
                cachePath,
                deletionPath
            )
        } else {
            do {
                try fileManager.moveItem(
                    atPath: cachePath,
                    toPath: deletionPath
                )
                reservation = 1
            } catch CocoaError.fileNoSuchFile {
                reservation = 2
            } catch {
                reservation = 0
            }
        }
        guard reservation != 0 else { return false }
        guard reservation != 2 else { return true }
        let worker = deletionWorker
        // The task is awaited before this lifecycle operation returns, so the
        // utility-priority filesystem work remains bounded by the caller and
        // cannot outlive the profile-deletion request as an unowned task.
        return await Task.detached(priority: .utility) {
            await worker.removeIfExists(atPath: deletionPath)
        }.value
    }
}
