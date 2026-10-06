import AppKit
import CmuxNextDesign
import os

// Wires NoActivateKeyboardGuard under CMUX_NEXT_NO_ACTIVATE=1: activation,
// key-window and other-app changes in, input from the app-wide event tap,
// each give-back into the input journal and `debug.focus`.
extension AppServices {
    func startNoActivateGuard() {
        guard WindowPlacement.noActivate else { return }
        let me = NSRunningApplication.current.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "focus.no-activate")
        let guardian = NoActivateKeyboardGuard(host: AppKitKeyboardGuardHost(), frontmost: frontmost == me ? nil : frontmost,
                                               onGiveBack: { giveBack in
            logger.notice("keyboard given back: \(giveBack.trigger.rawValue, privacy: .public), \(giveBack.cause, privacy: .public)")
            InputJournal.shared.append(window: nil, .keyboardGivenBack(trigger: giveBack.trigger.rawValue, cause: giveBack.cause,
                                                                        restoredTo: giveBack.restoredTo))
        })
        keyboardGuard = guardian
        let center = NotificationCenter.default
        keyboardGuardObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let pid = app?.processIdentifier, pid != me else { return }
            MainActor.assumeIsolated { guardian.otherAppActivated(pid) }
        })
        keyboardGuardObservers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { guardian.appDidBecomeActive() }
        })
        keyboardGuardObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { guardian.appDidResignActive() }
        })
        keyboardGuardObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { guardian.windowDidBecomeKey() }
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
        guardian.start()
    }
}
