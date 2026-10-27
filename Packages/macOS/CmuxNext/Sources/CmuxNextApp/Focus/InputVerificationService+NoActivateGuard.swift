import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextInput
import CmuxNextWakeups
import os

/// Resolves an application's PID off the main thread and replies on it. AppKit's `processIdentifier`
/// property can synchronously ask LaunchServices for dynamic properties.
private struct NoActivateApplicationResolver {
    let work: BackgroundWork
    let mainWork: MainWorkScheduler

    /// `application`'s PID; a nil `application` reads the frontmost one there.
    func resolve(_ application: NSRunningApplication?,
                 completion: @escaping @MainActor @Sendable (NSRunningApplication?, pid_t?) -> Void) {
        let given = application.map(NoActivateApplicationReference.init)
        work.run(.userVisible, mayBlock: .system) { () -> (NoActivateApplicationReference?, pid_t?) in
            let reference = given ?? NSWorkspace.shared.frontmostApplication.map(NoActivateApplicationReference.init)
            return (reference, reference?.application.processIdentifier)
        }.reply(on: mainWork, class: .visible, owner: "NoActivateKeyboardGuard.resolve") { resolved in
            completion(resolved.0?.application, resolved.1)
        }
    }
}

// Wires NoActivateKeyboardGuard under CMUX_NEXT_NO_ACTIVATE=1: activation,
// key-window and other-app changes in, key and mouse presses from the input tap,
// each give-back into the input journal and `debug.focus`.
extension InputVerificationService {
    /// Installs the guard in the launch turn (`AppServices.init`), before the app activates and its first
    /// window becomes key, so it sees both and resolves the app the person had in front. Once.
    ///
    /// - Parameters:
    ///   - tap: The app's input tap: the person's key and mouse presses.
    ///   - appEvents: The app's notices (`AppServices.appEvents`): activation and key-window changes.
    ///   - mainWork: The app's main-thread scheduler: the PID replies and the activation handoff.
    ///   - work: The app's off-main lanes: the PID reads.
    func startNoActivateGuard(tap: InputEventTap, appEvents: AppEvents, mainWork: MainWorkScheduler, work: BackgroundWork) {
        guard WindowPlacement.noActivate, keyboardGuard == nil else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "focus.no-activate")
        let guardian = NoActivateKeyboardGuard(host: AppKitKeyboardGuardHost(mainWork: mainWork), frontmost: nil,
                                               onGiveBack: { giveBack in
            logger.notice("keyboard given back: \(giveBack.trigger.rawValue, privacy: .public), \(giveBack.cause, privacy: .public)")
            InputJournal.shared.append(window: nil, .keyboardGivenBack(trigger: giveBack.trigger.rawValue, cause: giveBack.cause,
                                                                        restoredTo: giveBack.restoredTo))
        })
        keyboardGuard = guardian
        let resolver = NoActivateApplicationResolver(work: work, mainWork: mainWork)
        // An activated app (nil: the frontmost one) is where the keyboard goes back, unless it is this one.
        // A later activation begins a newer sequence; the guard drops a reply of an older one.
        let resolveActivated: @MainActor (NSRunningApplication?, UInt64) -> Void = { [weak self, weak guardian] app, sequence in
            resolver.resolve(app) { [weak self, weak guardian] app, pid in
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
        // A person's key or mouse press; the app's own synthetic input is not one.
        keyboardGuardSubscription = tap.subscribePresses([.keyDown, .mouseDown],
                                                         while: { application?.currentEventIsSynthetic != true }) { _ in
            guardian.userInput()
        }
        // Keep the no-activate invariant immediate. The previous app is
        // resolved off the main thread so this path never waits on
        // LaunchServices while installing observers.
        let initialApplicationSequence = guardian.beginOtherAppActivation()
        guardian.start()
        resolveActivated(nil, initialApplicationSequence)
    }
}
