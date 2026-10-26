import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextInput
import os

private enum NoActivateApplicationResolver {
    /// Resolves the PID off the main actor. AppKit's `processIdentifier`
    /// property can synchronously ask LaunchServices for dynamic properties.
    static func resolve(_ application: NSRunningApplication,
                        completion: @escaping @MainActor @Sendable (NSRunningApplication, pid_t) -> Void) {
        let reference = NoActivateApplicationReference(application)
        DispatchQueue.global(qos: .utility).async {
            let pid = reference.application.processIdentifier
            DispatchQueue.main.async {
                completion(reference.application, pid)
            }
        }
    }

    static func resolveFrontmost(completion: @escaping @MainActor @Sendable (NSRunningApplication?, pid_t?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let application = NSWorkspace.shared.frontmostApplication
            let reference = application.map(NoActivateApplicationReference.init)
            let pid = reference?.application.processIdentifier
            DispatchQueue.main.async {
                completion(reference?.application, pid)
            }
        }
    }
}

// Wires NoActivateKeyboardGuard under CMUX_NEXT_NO_ACTIVATE=1: activation,
// key-window and other-app changes in, key and mouse presses from the input tap,
// each give-back into the input journal and `debug.focus`.
extension InputVerificationService {
    /// Installs the guard in the launch turn (`AppServices.init`), before the app activates and its first
    /// window becomes key, so it sees both and resolves the app the person had in front. Once.
    func startNoActivateGuard(tap: InputEventTap) {
        guard WindowPlacement.noActivate, keyboardGuard == nil else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "focus.no-activate")
        let guardian = NoActivateKeyboardGuard(host: AppKitKeyboardGuardHost(), frontmost: nil,
                                               onGiveBack: { giveBack in
            logger.notice("keyboard given back: \(giveBack.trigger.rawValue, privacy: .public), \(giveBack.cause, privacy: .public)")
            InputJournal.shared.append(window: nil, .keyboardGivenBack(trigger: giveBack.trigger.rawValue, cause: giveBack.cause,
                                                                        restoredTo: giveBack.restoredTo))
        })
        keyboardGuard = guardian
        keyboardGuardObservers.append(MainActorObservation(
            NSWorkspace.didActivateApplicationNotification, center: NSWorkspace.shared.notificationCenter,
            read: { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }) { [weak guardian] app in
            guard let guardian, let app else { return }
            let sequence = guardian.beginOtherAppActivation()
            NoActivateApplicationResolver.resolve(app) { [weak self, weak guardian] app, pid in
                guard let self, let guardian, let current = self.keyboardGuard, current === guardian else { return }
                guard pid != me else { return }
                guardian.otherAppActivated(app, processIdentifier: pid, sequence: sequence)
                guardian.appDidBecomeActive()
            }
        })
        keyboardGuardObservers.append(MainActorObservation(NSApplication.didBecomeActiveNotification) { guardian.appDidBecomeActive() })
        keyboardGuardObservers.append(MainActorObservation(NSApplication.didResignActiveNotification) { guardian.appDidResignActive() })
        keyboardGuardObservers.append(MainActorObservation(NSWindow.didBecomeKeyNotification) { guardian.windowDidBecomeKey() })
        let application = NSApp as? CmuxApplication
        // A person's key or mouse press; the app's own synthetic input is not one.
        keyboardGuardSubscription = tap.subscribePresses([.keyDown, .mouseDown],
                                                         while: { application?.currentEventIsSynthetic != true }) { _ in
            guardian.userInput()
        }
        // Keep the no-activate invariant immediate. The previous app is
        // populated asynchronously below so this path never waits on
        // LaunchServices while installing observers.
        let initialApplicationSequence = guardian.beginOtherAppActivation()
        guardian.start()
        NoActivateApplicationResolver.resolveFrontmost { [weak self, weak guardian] app, pid in
            guard let self, let guardian, let current = self.keyboardGuard, current === guardian else { return }
            guard let app, let pid, pid != me else { return }
            guardian.otherAppActivated(app, processIdentifier: pid, sequence: initialApplicationSequence)
            guardian.appDidBecomeActive()
        }
    }
}
