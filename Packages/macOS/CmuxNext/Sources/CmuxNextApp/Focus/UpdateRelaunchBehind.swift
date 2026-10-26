@preconcurrency import AppKit
import CmuxNextUpdater
import CmuxNextWakeups
import os

/// The startup of a relaunch into an update nobody clicked, in an app the user was not in
/// (`UpdateRelaunchFocus`): the app comes back behind the app the user is in. LaunchServices
/// activates a relaunched app, and the launch itself asks to activate (`WindowActivation.activateApp`),
/// so for ``window`` after launch the app refuses its own activation (`CmuxApplication.refusesActivation`)
/// and `NoActivateKeyboardGuard` hands any activation without user intent back to the app that was
/// frontmost. Windows still open as they were; in an inactive app they stay behind the active one.
///
/// It ends at the first sign the user chose cmux (a click in it, Cmd-Tab or a click that activated
/// it, a Dock click) or after ``window``, whichever is first; from then on the app activates as
/// always. Keys do not end it: typing meant for the app the user is in may land in cmux in the
/// moment before the front is handed back.
@MainActor
final class UpdateRelaunchBehind {
    /// How long after launch an activation counts as the relaunch's, not the user's.
    static let window: Duration = .seconds(8)

    private let application: CmuxApplication?
    private let guardian: NoActivateKeyboardGuard
    private var observers: [any NSObjectProtocol] = []
    private var inputMonitor: Any?
    private let deadline = DemandTimer(owner: "UpdateRelaunchBehind.window")
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "focus.update-relaunch")
    private(set) var isRunning = false

    init(application: CmuxApplication?) {
        self.application = application
        let logger = logger
        guardian = NoActivateKeyboardGuard(host: AppKitKeyboardGuardHost(), frontmost: nil) { giveBack in
            logger.notice("update relaunch: front given back (\(giveBack.trigger.rawValue, privacy: .public))")
        }
    }

    /// Starts the scope for `record` (consumed at launch). Call once, at launch, before the first
    /// window opens; `refusesActivation` is already on (`CmuxNextApp.main`).
    func start(_ record: UpdateRelaunchFocus) {
        guard !isRunning else { return }
        isRunning = true
        application?.refusesActivation = true
        logger.notice("update relaunch: staying behind \(record.frontmostBundleID ?? "the frontmost app", privacy: .public)")
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidBecomeActive() } // main-proof: observer on queue: .main
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.guardian.appDidResignActive() } // main-proof: observer on queue: .main
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.guardian.windowDidBecomeKey() } // main-proof: observer on queue: .main
        })
        // The user moved to another app meanwhile: that is where the front goes back.
        let me = ProcessInfo.processInfo.processIdentifier
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.otherApp(app, me: me) } // main-proof: observer on queue: .main
        })
        // A click the user gave a cmux window ends the scope.
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { // main-proof: local event monitors run on the main thread
                if self?.application?.currentEventIsSynthetic != true { self?.end(reason: "user click") }
            }
            return event
        }
        deadline.schedule(after: Self.window) { @MainActor [weak self] in self?.end(reason: "window ended") }
        // The app that had the front when the relaunch began; resolved off the main actor
        // (`NSRunningApplication` lookups ask LaunchServices).
        let sequence = guardian.beginOtherAppActivation()
        let pid = record.frontmostPID, bundleID = record.frontmostBundleID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let app = Self.runningApp(pid: pid, bundleID: bundleID, excluding: me)
            let reference = app.map(NoActivateApplicationReference.init)
            let resolvedPID = reference?.application.processIdentifier
            DispatchQueue.main.async {
                MainActor.assumeIsolated { // main-proof: DispatchQueue.main
                    guard let self, self.isRunning else { return }
                    if let reference, let resolvedPID {
                        self.guardian.otherAppActivated(reference.application, processIdentifier: resolvedPID, sequence: sequence)
                    }
                    self.guardian.appDidBecomeActive()
                }
            }
        }
        // LaunchServices may have activated the app before anything observed it.
        guardian.start()
    }

    nonisolated private static func runningApp(pid: Int32?, bundleID: String?, excluding me: pid_t) -> NSRunningApplication? {
        if let pid, pid != me, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated { return app }
        guard let bundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { $0.processIdentifier != me && !$0.isTerminated }
    }

    private func appDidBecomeActive() {
        guard isRunning else { return }
        // A click on a cmux window or Cmd-Tab: the user chose cmux.
        if NSEvent.pressedMouseButtons != 0 || NSEvent.modifierFlags.contains(.command) {
            return end(reason: "user activated")
        }
        guardian.appDidBecomeActive()
    }

    private func otherApp(_ app: NSRunningApplication, me: pid_t) {
        guard isRunning else { return }
        let sequence = guardian.beginOtherAppActivation()
        let reference = NoActivateApplicationReference(app)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let pid = reference.application.processIdentifier
            DispatchQueue.main.async {
                MainActor.assumeIsolated { // main-proof: DispatchQueue.main
                    guard let self, self.isRunning, pid != me else { return }
                    self.guardian.otherAppActivated(reference.application, processIdentifier: pid, sequence: sequence)
                }
            }
        }
    }

    /// A Dock click on cmux: the user chose it. Ends the scope and activates, in case the front
    /// was handed back before the reopen arrived. False when no scope runs.
    func userReopened() -> Bool {
        guard isRunning else { return false }
        end(reason: "dock click")
        NSApp.activate()
        return true
    }

    /// The scope ends: the app activates as always from here.
    func end(reason: String) {
        guard isRunning else { return }
        isRunning = false
        application?.refusesActivation = false
        deadline.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        logger.notice("update relaunch: activation allowed again (\(reason, privacy: .public), \(self.guardian.giveBackCount) give-backs)")
    }
}
