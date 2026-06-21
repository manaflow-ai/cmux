public import AppKit

/// Performs the window/app-lifecycle bootstrap steps cmux runs once shortly
/// after launch: registering this bundle with LaunchServices, terminating any
/// already-running instance of the same bundle (single-instance enforcement),
/// and installing the duplicate-launch observer that terminates later
/// duplicate instances as they appear.
///
/// Lifted byte-for-byte from `AppDelegate.scheduleLaunchServicesBundleRegistration`,
/// `AppDelegate.enforceSingleInstance`, and `AppDelegate.observeDuplicateLaunches`.
/// Those bodies only ever read process/bundle/`NSRunningApplication`/`NSWorkspace`
/// state plus emitted breadcrumbs, so they belong in the windowing domain rather
/// than on the `NSApplicationDelegate`. The `NSApplicationDelegate` lifecycle
/// callback that *triggers* this stays an app-target shim that constructs this
/// instance and forwards.
///
/// Design: the type holds no mutable state. Every collaborator that touches
/// app-target globals (the LaunchServices serial-queue scheduler, the
/// `LSRegisterURL` call, the Sentry/startup breadcrumb sinks, `NSWorkspace`) is
/// constructor-injected, so the package never imports the app target and the
/// behavior is unit-testable with fakes. It is `@MainActor` because the
/// single-instance and duplicate-launch flows read `NSRunningApplication`/
/// `NSWorkspace` notification state on the main actor, matching the legacy call
/// sites that ran inside `DispatchQueue.main.async`.
@MainActor
public struct AppLaunchBootstrap {
    private let bundleIdentifier: String?
    private let bundleURL: URL
    private let currentPid: Int32
    private let workspace: NSWorkspace
    private let runningApplications: @MainActor (_ bundleIdentifier: String) -> [NSRunningApplication]
    private let activateCurrent: @MainActor () -> Void
    private let startupBreadcrumb: @MainActor (_ event: String, _ fields: [String: String]) -> Void

    /// Creates a launch bootstrapper.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: This app's bundle identifier (production:
    ///     `Bundle.main.bundleIdentifier`). When `nil`, single-instance and
    ///     duplicate-launch steps no-op after emitting a skip breadcrumb,
    ///     matching the legacy guard.
    ///   - bundleURL: This app's bundle URL (production:
    ///     `Bundle.main.bundleURL`); used both for LaunchServices registration
    ///     and to resolve the embedded CLI executable that duplicate-launch
    ///     observation deliberately ignores.
    ///   - currentPid: This process's identifier (production:
    ///     `ProcessInfo.processInfo.processIdentifier`).
    ///   - workspace: The `NSWorkspace` whose notification center the
    ///     duplicate-launch observer registers on (production: `.shared`).
    ///   - runningApplications: Resolves the currently-running applications for a
    ///     bundle identifier (production:
    ///     `NSRunningApplication.runningApplications(withBundleIdentifier:)`).
    ///   - activateCurrent: Activates this application's windows after
    ///     terminating a duplicate (production:
    ///     `NSRunningApplication.current.activate(options:)`).
    ///   - startupBreadcrumb: Emits a startup breadcrumb line (production:
    ///     `StartupBreadcrumbLog.append(_:fields:)`).
    public init(
        bundleIdentifier: String?,
        bundleURL: URL,
        currentPid: Int32,
        workspace: NSWorkspace = .shared,
        runningApplications: @escaping @MainActor (_ bundleIdentifier: String) -> [NSRunningApplication],
        activateCurrent: @escaping @MainActor () -> Void,
        startupBreadcrumb: @escaping @MainActor (_ event: String, _ fields: [String: String]) -> Void
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.currentPid = currentPid
        self.workspace = workspace
        self.runningApplications = runningApplications
        self.activateCurrent = activateCurrent
        self.startupBreadcrumb = startupBreadcrumb
    }

    /// Schedules LaunchServices registration of this app bundle off the main
    /// thread, emitting schedule/complete breadcrumbs and logging a failure.
    ///
    /// Byte-faithful to the legacy `scheduleLaunchServicesBundleRegistration`:
    /// the bundle URL is standardized, the register work is handed to the
    /// injected scheduler (production: a utility serial queue), and the same
    /// `launchservices.register.schedule` / `launchservices.register.complete`
    /// breadcrumbs (including `durationMs` and integer `status`) are emitted via
    /// the injected breadcrumb sink (production: `sentryBreadcrumb`).
    ///
    /// - Parameters:
    ///   - scheduler: Runs the registration work off the main thread.
    ///   - register: Performs the LaunchServices registration for a `CFURL`,
    ///     returning its `OSStatus`.
    ///   - breadcrumb: Emits a registration breadcrumb with arbitrary fields.
    public func scheduleLaunchServicesRegistration(
        scheduler: @escaping (@escaping @Sendable () -> Void) -> Void,
        register: @escaping @Sendable (CFURL) -> OSStatus,
        breadcrumb: @escaping @Sendable (_ message: String, _ data: [String: Any]) -> Void
    ) {
        let normalizedURL = bundleURL.standardizedFileURL
        breadcrumb("launchservices.register.schedule", [
            "bundlePath": normalizedURL.path
        ])

        scheduler {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let registerStatus = register(normalizedURL as CFURL)
            let durationMs = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000).rounded())

            breadcrumb("launchservices.register.complete", [
                "bundlePath": normalizedURL.path,
                "status": Int(registerStatus),
                "durationMs": durationMs
            ])

            if registerStatus != noErr {
                NSLog("LaunchServices registration failed (status: \(registerStatus)) for \(normalizedURL.path)")
            }
        }
    }

    /// Terminates every other running instance of this app bundle, leaving only
    /// the current process.
    ///
    /// Byte-faithful to the legacy `enforceSingleInstance`: skips with a
    /// `singleInstance.enforce.skip` breadcrumb when the bundle identifier is
    /// unknown; otherwise terminates each running application other than the
    /// current pid (escalating to `forceTerminate()` when a graceful terminate
    /// does not take), then emits `singleInstance.enforce.complete` with the
    /// comma-joined terminated pids.
    public func enforceSingleInstance() {
        guard let bundleId = bundleIdentifier else {
            startupBreadcrumb("singleInstance.enforce.skip", ["reason": "missingBundleId"])
            return
        }
        var terminatedPids: [String] = []

        for app in runningApplications(bundleId) {
            guard app.processIdentifier != currentPid else { continue }
            terminatedPids.append(String(app.processIdentifier))
            app.terminate()
            if !app.isTerminated {
                _ = app.forceTerminate()
            }
        }
        startupBreadcrumb(
            "singleInstance.enforce.complete",
            [
                "bundleIdentifier": bundleId,
                "currentPid": String(currentPid),
                "terminatedPids": terminatedPids.joined(separator: ",")
            ]
        )
    }

    /// Installs an observer that terminates later-launched duplicate instances of
    /// this app bundle, ignoring the embedded CLI helper.
    ///
    /// Byte-faithful to the legacy `observeDuplicateLaunches`: skips with a
    /// `singleInstance.observe.skip` breadcrumb when the bundle identifier is
    /// unknown; otherwise registers an `NSWorkspace.didLaunchApplicationNotification`
    /// observer on the main queue that ignores the embedded CLI executable
    /// (`Contents/Resources/bin/cmux`), terminates any other instance of the same
    /// bundle (escalating to `forceTerminate()`), re-activates the current app,
    /// and emits the same `singleInstance.observe.install` /
    /// `singleInstance.observe.terminateDuplicate` breadcrumbs.
    ///
    /// - Returns: The observer token, or `nil` when skipped. The caller owns it
    ///   and is responsible for its lifetime, exactly as the legacy
    ///   `workspaceObserver` stored property did.
    public func observeDuplicateLaunches() -> (any NSObjectProtocol)? {
        guard let bundleId = bundleIdentifier else {
            startupBreadcrumb("singleInstance.observe.skip", ["reason": "missingBundleId"])
            return nil
        }
        let embeddedCLIURL = bundleURL
            .appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let currentPid = currentPid
        let activateCurrent = activateCurrent
        let startupBreadcrumb = startupBreadcrumb
        startupBreadcrumb(
            "singleInstance.observe.install",
            [
                "bundleIdentifier": bundleId,
                "currentPid": String(currentPid)
            ]
        )

        // The observer is delivered on `queue: .main`, so the body is always on
        // the main actor at runtime; `assumeIsolated` is the faithful bridge for
        // a `.main`-queue NotificationCenter callback (it lets the body call the
        // injected `@MainActor` `activateCurrent`/`startupBreadcrumb` closures),
        // not a manufactured isolation domain. This mirrors the legacy
        // `AppDelegate.installMainWindowKeyObserver` callback in the same file.
        return workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            // The notification is delivered on the main queue, so its userInfo is
            // read on the main thread; `nonisolated(unsafe)` lifts the resolved
            // `NSRunningApplication` into the main-actor body without the
            // task-isolated `notification` value crossing the boundary.
            nonisolated(unsafe) let launchedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let app = launchedApp else { return }
                guard app.bundleIdentifier == bundleId, app.processIdentifier != currentPid else { return }
                if let executableURL = app.executableURL?
                       .standardizedFileURL
                       .resolvingSymlinksInPath(),
                   executableURL == embeddedCLIURL {
                    return
                }

                startupBreadcrumb(
                    "singleInstance.observe.terminateDuplicate",
                    [
                        "duplicatePid": String(app.processIdentifier),
                        "duplicateBundleIdentifier": app.bundleIdentifier ?? "nil"
                    ]
                )
                app.terminate()
                if !app.isTerminated {
                    _ = app.forceTerminate()
                }
                activateCurrent()
            }
        }
    }
}
