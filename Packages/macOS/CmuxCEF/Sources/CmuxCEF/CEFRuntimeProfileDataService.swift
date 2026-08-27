public import Foundation
internal import CmuxCEFShim

/// Removes a named CEF profile directory only after the process-local request
/// context registry confirms that no live browser uses it.
@MainActor
public final class CEFRuntimeProfileDataService {
    private let fileManager: FileManager
    private let runtimeIsInitialized: () -> Bool
    private let profileCacheIsIdle: (String) -> Bool

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
    }

    /// Removes `cachePath` when it is safe to do so in the current process.
    ///
    /// The check and removal are intentionally synchronous on the CEF UI thread:
    /// no browser can be created between them, and the shared CEF root is never
    /// removed by this API.
    ///
    /// - Parameter cachePath: A named profile cache path below CEF's root.
    /// - Returns: `true` when the path was removed or did not exist; `false`
    ///   when a live request context still owns it.
    @discardableResult
    public func removeIfIdle(at cachePath: String) -> Bool {
        guard !runtimeIsInitialized() || profileCacheIsIdle(cachePath) else {
            return false
        }
        do {
            try fileManager.removeItem(atPath: cachePath)
            return true
        } catch CocoaError.fileNoSuchFile {
            return true
        } catch {
            return false
        }
    }
}
