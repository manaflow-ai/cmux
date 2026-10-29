import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextInput
import CmuxNextUpdater
import CmuxNextWakeups
import os

/// Resolves an application's PID off the main thread and replies on it. AppKit's `processIdentifier`
/// property can synchronously ask LaunchServices for dynamic properties.
private struct NoActivateApplicationResolver {
    let work: BackgroundWork
    let mainWork: MainWorkScheduler

    /// `application`'s PID; a nil `application` reads the frontmost one there, or with `relaunch` the app
    /// that was frontmost when the update relaunch began (by its pid; nil when it quit since, and the
    /// front then goes to the next app in line).
    func resolve(_ application: NSRunningApplication?, relaunch: UpdateRelaunchFocus? = nil,
                 completion: @escaping @MainActor @Sendable (NSRunningApplication?, pid_t?) -> Void) {
        let given = application.map(NoActivateApplicationReference.init)
        let recorded = relaunch != nil, recordedPID = relaunch?.frontmostPID
        work.run(.userVisible, mayBlock: .system) { () -> (NoActivateApplicationReference?, pid_t?) in
            let me = ProcessInfo.processInfo.processIdentifier
            let frontmost = if !recorded { NSWorkspace.shared.frontmostApplication } else {
                recordedPID.flatMap { $0 == me ? nil : NSRunningApplication(processIdentifier: $0) }
            }
            let reference = given ?? frontmost.map(NoActivateApplicationReference.init)
            return (reference, reference?.application.processIdentifier)
        }.reply(on: mainWork, class: .visible, owner: "NoActivateKeyboardGuard.resolve") { resolved in
            completion(resolved.0?.application, resolved.1)
        }
    }
}

// Wires NoActivateKeyboardGuard under CMUX_NEXT_NO_ACTIVATE=1: activation,
// key-window and other-app changes in, key and mouse presses from the input tap,
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

    /// Installs the guard in the launch turn (`AppServices.init`), before the app activates and its first
    /// window becomes key, so it sees both and resolves the app the person had in front. Once.
    ///
    /// - Parameters:
    ///   - tap: The app's input tap: the person's key and mouse presses.
    ///   - appEvents: The app's notices (`AppServices.appEvents`): activation and key-window changes.
    ///   - mainWork: The app's main-thread scheduler: the PID replies and the activation handoff.
    ///   - work: The app's off-main lanes: the PID reads.
    ///   - relaunch: This launch is an update relaunch nobody clicked (`AppEnvironment.relaunchBehind`):
    ///     the guard runs for its startup only, outside no-activate mode.
    func startNoActivateGuard(tap: InputEventTap, appEvents: AppEvents, mainWork: MainWorkScheduler, work: BackgroundWork,
                              relaunch: UpdateRelaunchFocus? = nil) {
        guard WindowPlacement.noActivate || relaunch != nil, keyboardGuard == nil else { return }
        let relaunchOnly = !WindowPlacement.noActivate
        let me = ProcessInfo.processInfo.processIdentifier
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "focus.no-activate")
        let host = AppKitKeyboardGuardHost(mainWork: mainWork)
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
        let resolver = NoActivateApplicationResolver(work: work, mainWork: mainWork)
        // An activated app (nil: the frontmost one, or the update relaunch's recorded one) is where the keyboard
        // goes back, unless it is this one. A later activation begins a newer sequence; the guard drops a reply of an older one.
        let resolveActivated: @MainActor (NSRunningApplication?, UInt64) -> Void = { [weak self, weak guardian] app, sequence in
            resolver.resolve(app, relaunch: app == nil ? relaunch : nil) { [weak self, weak guardian] app, pid in
                guard let self, let guardian, let current = self.keyboardGuard, current === guardian else { return }
                guard let app, let pid, pid != me else { return }
                guardian.otherAppActivated(app, processIdentifier: pid, sequence: sequence)
                guardian.appDidBecomeActive()
            }
        }
        // raw-observer-allow: the guard needs the notice's userInfo (the app that activated); an AppEvents call carries no payload
        keyboardGuardActivation = MainActorObservation(NSWorkspace.didActivateApplicationNotification, center: NSWorkspace.shared.notificationCenter,
                                                       read: { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }) { [weak guardian] app in
            guard let guardian, let app else { return }
            resolveActivated(app, guardian.beginOtherAppActivation())
        }
        let owner = "NoActivateKeyboardGuard"
        keyboardGuardSubscriptions = [
            appEvents.subscribe(NSApplication.didBecomeActiveNotification, owner: owner) { guardian.appDidBecomeActive() },
            appEvents.subscribe(NSApplication.didResignActiveNotification, owner: owner) { guardian.appDidResignActive() },
            appEvents.subscribe(NSWindow.didBecomeKeyNotification, owner: owner) { guardian.windowDidBecomeKey() },
        ]
        let application = NSApp as? CmuxApplication
        // A person's key or mouse press; the app's own synthetic input is not one. In an update relaunch's
        // startup a click ends it (the user chose cmux); keys do not.
        keyboardGuardSubscription = tap.subscribePresses([.keyDown, .mouseDown],
                                                         while: { application?.currentEventIsSynthetic != true }) { [weak self] event in
            if !relaunchOnly {
                guardian.userInput()
            } else if event.type != .keyDown {
                self?.endRelaunchBehind("user click")
            }
        }
        // Keep the no-activate invariant immediate. The previous app is
        // resolved off the main thread so this path never waits on
        // LaunchServices while installing observers.
        let initialApplicationSequence = guardian.beginOtherAppActivation()
        guardian.start()
        resolveActivated(nil, initialApplicationSequence)
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
        keyboardGuardActivation = nil
        keyboardGuardSubscriptions.removeAll()
        keyboardGuardSubscription = nil
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
