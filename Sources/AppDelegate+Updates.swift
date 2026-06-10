import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - Update checks, update pill, and log copying
extension AppDelegate {
    @objc func checkForUpdates(_ sender: Any?) {
        updateController.model.setOverrideState(nil)
        updateController.checkForUpdates()
    }

    func checkForUpdatesInCustomUI() {
        updateController.model.setOverrideState(nil)
        updateController.checkForUpdatesInCustomUI()
    }

    @objc func applyUpdateIfAvailable(_ sender: Any?) {
        updateController.model.setOverrideState(nil)
        updateController.installUpdate()
    }

    @objc func attemptUpdate(_ sender: Any?) {
        updateController.model.setOverrideState(nil)
        updateController.attemptUpdate()
    }

    #if DEBUG
    @objc func showUpdatePill(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateController.model.setOverrideState(.installing(.init(isAutoUpdate: true, retryTerminatingApplication: {}, dismiss: {})))
    }

    @objc func showUpdatePillLongNightly(_ sender: Any?) {
        updateViewModel.debugOverrideText = "Update Available: 0.32.0-nightly+20260216.abc1234"
        updateController.model.setOverrideState(.notFound(.init(acknowledgement: {})))
    }

    @objc func showUpdatePillLoading(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateController.model.setOverrideState(.checking(.init(cancel: {})))
    }

    @objc func hideUpdatePill(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateController.model.setOverrideState(.idle)
    }

    @objc func clearUpdatePillOverride(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateController.model.setOverrideState(nil)
    }
#endif

    @objc func copyUpdateLogs(_ sender: Any?) {
        let logText = updateLog.snapshot()
        let payload: String
        if logText.isEmpty {
            payload = "No update logs captured.\nLog file: \(updateLog.logPath())"
        } else {
            payload = logText + "\nLog file: \(updateLog.logPath())"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }
    @objc func copyFocusLogs(_ sender: Any?) {
        let logText = focusLog.snapshot()
        let payload: String
        if logText.isEmpty {
            payload = "No focus logs captured.\nLog file: \(focusLog.logPath())"
        } else {
            payload = logText + "\nLog file: \(focusLog.logPath())"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

    func attachUpdateAccessory(to window: NSWindow) {
        titlebarAccessoryController.start()
        titlebarAccessoryController.attach(to: window)
    }

    func applyWindowDecorations(to window: NSWindow) {
        windowDecorationsController.apply(to: window)
    }

}
