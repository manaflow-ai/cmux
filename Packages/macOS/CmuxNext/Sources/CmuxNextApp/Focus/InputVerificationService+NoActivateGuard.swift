@preconcurrency import AppKit
import CmuxNextDesign
import CmuxNextUpdater
import CmuxNextWakeups
import os

private enum NoActivateApplicationResolver {
    /// Resolves the PID off the main actor. AppKit's `processIdentifier`
    /// property can synchronously ask LaunchServices for dynamic properties.
    static func resolve(_ application: NSRunningApplication,
                        completion: @escaping @MainActor (NSRunningApplication, pid_t) -> Void) {
        let reference = NoActivateApplicationReference(application)
        DispatchQueue.global(qos: .utility).async {
            let pid = reference.application.processIdentifier
            DispatchQueue.main.async {
                completion(reference.application, pid)
            }
        }
    }

    /// The frontmost app, or with `relaunch` the app that was frontmost when the update relaunch
    /// began (by its pid; nil when it quit since, and the front then goes to the next app in line).
    static func resolveFrontmost(relaunch: UpdateRelaunchFocus? = nil,
                                 completion: @escaping @MainActor (NSRunningApplication?, pid_t?) -> Void) {
        let recorded = relaunch != nil, recordedPID = relaunch?.frontmostPID
        DispatchQueue.global(qos: .utility).async {
            let me = ProcessInfo.processInfo.processIdentifier
            let application = if !recorded { NSWorkspace.shared.frontmostApplication } else {
                recordedPID.flatMap { $0 == me ? nil : NSRunningApplication(processIdentifier: $0) }
            }
            let reference = application.map(NoActivateApplicationReference.init)
            let pid = reference?.application.processIdentifier
            DispatchQueue.main.async {
                completion(reference?.application, pid)
            }
        }
    }
}

// Wires NoActivateKeyboardGuard under CMUX_NEXT_NO_ACTIVATE=1: activation,
// key-window and other-app changes in, input from the app-wide event tap,
// each give-back into the input journal and `debug.focus`.
//
// The same guard runs for the startup of an update relaunch nobody clicked, in an app the user
// was not in (`UpdateRelaunchFocus`): LaunchServices activates a relaunched app, so the activation
// goes back to the app that had the front when the relaunch began, and the app refuses its own
// activation (`CmuxApplication.refusesActivation`, on from `CmuxNextApp.main`). That scope ends at
// the first sign the user chose cmux (a click in it, Cmd-Tab or a click that activated it, a Dock
// click) or after `relaunchBehindWindow`; from then on the app activates as always. Keys do not
// end it, nor count as intent: typing meant for the user's app may land in cmux in the moment
// before the front goes back.
extension InputVerificationService {
    /// How long after launch an activation counts as the update relaunch's, not the user's.
    static let relaunchBehindWindow: Duration = .seconds(8)

    func startNoActivateGuard(relaunch: UpdateRelaunchFocus? = nil) {
        guard WindowPlacement.noActivate || relaunch != nil else { return }
        let relaunchOnly = !WindowPlacement.noActivate
        let me = ProcessInfo.processInfo.processIdentifier
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "focus.no-activate")
        let host = AppKitKeyboardGuardHost()
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: nil,
                                               onGiveBack: { giveBack in
            logger.notice("keyboard given back: \(giveBack.trigger.rawValue, privacy: .public), \(giveBack.cause, privacy: .public)")
            InputJournal.shared.append(window: nil, .keyboardGivenBack(trigger: giveBack.trigger.rawValue, cause: giveBack.cause,
                                                                        restoredTo: giveBack.restoredTo))
        })
        keyboardGuard = guardian
        host.stopped = { [weak guardian] in guardian?.isEnabled == false }
        if relaunchOnly {
            logger.notice("update relaunch: staying behind \(relaunch?.frontmostBundleID ?? "the frontmost app", privacy: .public)")
            guardian.onUserChose = { [weak self] in self?.endRelaunchBehind("user activated") }
            guardian.ignoresHeldInputUntil = .now + NoActivateKeyboardGuard.launchActivationGrace
            let end = DemandTimer(owner: "InputVerificationService.relaunchBehind")
            relaunchBehindEnd = end
            end.schedule(after: Self.relaunchBehindWindow) { @MainActor [weak self] in self?.endRelaunchBehind("window ended") }
        }
        let center = NotificationCenter.default
        keyboardGuardObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak guardian] note in
            guard let guardian else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let sequence = guardian.beginOtherAppActivation()
            NoActivateApplicationResolver.resolve(app) { [weak self, weak guardian] app, pid in
                guard let self, let guardian, let current = self.keyboardGuard, current === guardian else { return }
                guard pid != me else { return }
                guardian.otherAppActivated(app, processIdentifier: pid, sequence: sequence)
                guardian.appDidBecomeActive()
            }
        })
        keyboardGuardObservers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { guardian.appDidBecomeActive() } // main-proof: observer on queue: .main
        })
        keyboardGuardObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { guardian.appDidResignActive() } // main-proof: observer on queue: .main
        })
        keyboardGuardObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { guardian.windowDidBecomeKey() } // main-proof: observer on queue: .main
        })
        let application = NSApp as? CmuxApplication
        let journalObserver = application?.inputObserver
        application?.inputObserver = { [weak self] event in
            switch event.type {
            case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
                guard application?.currentEventIsSynthetic != true else { break }
                if !relaunchOnly {
                    guardian.userInput()
                } else if event.type != .keyDown {
                    self?.endRelaunchBehind("user click")
                }
            default: break
            }
            journalObserver?(event)
        }
        // Keep the no-activate invariant immediate. The previous app is
        // populated asynchronously below so this path never waits on
        // LaunchServices while installing observers.
        let initialApplicationSequence = guardian.beginOtherAppActivation()
        guardian.start()
        NoActivateApplicationResolver.resolveFrontmost(relaunch: relaunch) { [weak self, weak guardian] app, pid in
            guard let self, let guardian, let current = self.keyboardGuard, current === guardian else { return }
            guard let app, let pid, pid != me else { return }
            guardian.otherAppActivated(app, processIdentifier: pid, sequence: initialApplicationSequence)
            guardian.appDidBecomeActive()
        }
    }

    /// Ends an update relaunch's startup behind the user's app: the guard stops and the app
    /// activates as always. `activating` (a Dock click) activates it too, in case the front went back
    /// before the reopen arrived. False when no such startup runs.
    /// An update relaunch's startup behind the user's app runs.
    var isRelaunchBehind: Bool { relaunchBehindEnd != nil }

    @discardableResult
    func endRelaunchBehind(_ reason: String, activating: Bool = false) -> Bool {
        guard let end = relaunchBehindEnd else { return false }
        relaunchBehindEnd = nil
        end.cancel()
        keyboardGuard?.isEnabled = false
        keyboardGuard?.onUserChose = nil
        for observer in keyboardGuardObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        keyboardGuardObservers.removeAll()
        (NSApp as? CmuxApplication)?.refusesActivation = false
        Logger(subsystem: "com.cmuxterm.app.next", category: "focus.no-activate")
            .notice("update relaunch: activation allowed again (\(reason, privacy: .public))")
        if activating { NSApp.activate() }
        // A restored full-screen window waited for the startup's end (`enterRestoredFullScreens`); it
        // enters now if the user is in cmux, else the next time a window is presented.
        if NSApp.isActive { services?.windows.enterRestoredFullScreens() }
        return true
    }
}
