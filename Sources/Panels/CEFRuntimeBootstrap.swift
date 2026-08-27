import CmuxBrowser
import CmuxCEF
import Foundation

/// Composition boundary for the in-process CEF runtime.
///
/// CEF initializes once per process, on first Chromium pane. Settings are
/// captured at that moment: extension directories and the remote-debugging
/// port apply from the next app launch when changed later, matching Chrome's
/// own command-line semantics.
@MainActor
enum CEFRuntimeBootstrap {
    private static var appLaunchCompleted = false
    private static var launchWaiters: [CheckedContinuation<Void, Never>] = []

    /// Whether this build embeds the CEF framework. Cheap enough to call
    /// during pane construction; performs no initialization.
    static var isRuntimeAvailable: Bool {
        guard let frameworks = Bundle.main.privateFrameworksPath else { return false }
        return FileManager.default.fileExists(
            atPath: (frameworks as NSString)
                .appendingPathComponent("Chromium Embedded Framework.framework")
        )
    }

    /// AppDelegate calls this when `applicationDidFinishLaunching` returns.
    /// CEF's chrome-style bootstrap crashes when initialized from inside the
    /// AppKit launch callout (which is where session restore creates panes),
    /// so initialization waits for this signal.
    static func noteAppLaunchComplete() {
        appLaunchCompleted = true
        let waiters = launchWaiters
        launchWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Suspends until CEF may initialize: launch complete, plus one main-queue
    /// hop so execution is outside the launch callout entirely.
    static func waitUntilSafeToInitialize() async {
        if !appLaunchCompleted {
            await withCheckedContinuation { continuation in
                launchWaiters.append(continuation)
            }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Root for all CEF-owned storage, namespaced by bundle identifier.
    static var rootCachePath: String {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        return base
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("CEFCache", isDirectory: true)
            .path
    }

    /// Per-profile cache directory below the root, as CEF requires.
    ///
    /// - Parameters:
    ///   - profileID: Logical cmux browser profile.
    ///   - storageID: Optional child-process identity. CEF callers omit it so
    ///     the shim can share one request context per logical profile; the
    ///     out-of-process fallback supplies it to avoid profile-lock clashes.
    /// - Returns: Absolute cache path for that profile's request context.
    static func profileCachePath(for profileID: UUID, storageID: UUID? = nil) -> String {
        var path = (rootCachePath as NSString).appendingPathComponent(
            "Profiles/\(profileID.uuidString)"
        )
        if let storageID {
            path = (path as NSString).appendingPathComponent(
                "Panes/\(storageID.uuidString)"
            )
        }
        return path
    }

    /// Removes CEF data for one profile after all of its panes have stopped.
    static func removeProfileData(for profileID: UUID) async {
        let fileManager = FileManager.default
        if profileID == BrowserProfileRepository.builtInDefaultProfileID {
            let root = URL(fileURLWithPath: rootCachePath, isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }
            // Named profiles live below Profiles/; the remaining root entries
            // belong to CEF's shared default request context.
            let entriesToRemove = entries.filter { $0.lastPathComponent != "Profiles" }
            await Task.detached(priority: .utility) {
                let fileManager = FileManager.default
                for entry in entriesToRemove { try? fileManager.removeItem(at: entry) }
            }.value
            return
        }
        let profileURL = URL(fileURLWithPath: profileCachePath(for: profileID), isDirectory: true)
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: profileURL)
        }.value
    }

    /// Initializes CEF on first use.
    ///
    /// - Returns: `true` when the runtime is available for browser creation.
    @discardableResult
    static func initializeIfNeeded() -> Bool {
        if CEFRuntime.isInitialized { return true }
        let settings = BrowserEngineSettingsStore(defaults: .standard)
        let extensionDirectories = settings.chromiumExtensionDirectories()
            .map(\.path)
            .joined(separator: "\n")
        let requestedPort = settings.remoteDebuggingPort()
        // CEF CHECK-fails fast when its cache root is missing; create it
        // before initialization. Chromium logs to stderr in Debug builds.
        try? FileManager.default.createDirectory(
            atPath: rootCachePath,
            withIntermediateDirectories: true
        )
        let options = CEFRuntime.Options(
            rootCachePath: rootCachePath,
            extensionDirectories: extensionDirectories,
            remoteDebuggingPort: requestedPort.isExternallyAttachable
                ? requestedPort.rawValue
                : 0,
            frameworkDirectory: nil,
            logFilePath: nil
        )
        return CEFRuntime.initialize(options: options)
    }
}
