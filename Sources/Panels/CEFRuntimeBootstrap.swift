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
    /// - Parameter profileID: Logical cmux browser profile.
    /// - Returns: Absolute cache path for that profile's request context.
    static func profileCachePath(for profileID: UUID) -> String {
        (rootCachePath as NSString).appendingPathComponent(
            "Profiles/\(profileID.uuidString)"
        )
    }

    /// Removes the isolated CEF request-context cache for a non-default profile.
    ///
    /// The built-in profile intentionally uses CEF's shared global context and
    /// therefore has no profile-specific directory to delete.
    static func removeProfileData(for profileID: UUID) {
        guard profileID != BrowserProfileRepository.builtInDefaultProfileID else { return }
        try? FileManager.default.removeItem(atPath: profileCachePath(for: profileID))
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
