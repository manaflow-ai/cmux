@preconcurrency import AppKit
import CmuxNextDesign
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

    static func resolveFrontmost(completion: @escaping @MainActor (NSRunningApplication?, pid_t?) -> Void) {
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
// key-window and other-app changes in, input from the app-wide event tap,
// each give-back into the input journal and `debug.focus`.
extension InputVerificationService {
    func startNoActivateGuard() {
        guard WindowPlacement.noActivate else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "focus.no-activate")
        let guardian = NoActivateKeyboardGuard(host: AppKitKeyboardGuardHost(), frontmost: nil,
                                               onGiveBack: { giveBack in
            logger.notice("keyboard given back: \(giveBack.trigger.rawValue, privacy: .public), \(giveBack.cause, privacy: .public)")
            InputJournal.shared.append(window: nil, .keyboardGivenBack(trigger: giveBack.trigger.rawValue, cause: giveBack.cause,
                                                                        restoredTo: giveBack.restoredTo))
        })
        keyboardGuard = guardian
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
        application?.inputObserver = { event in
            switch event.type {
            case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
                if application?.currentEventIsSynthetic != true { guardian.userInput() }
            default: break
            }
            journalObserver?(event)
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
