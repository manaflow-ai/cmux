import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC


// MARK: - Toolbar Button Actions
extension BrowserPanelView {
    func handleReloadOrStopButtonAction() {
        if panel.isLoading {
#if DEBUG
            cmuxDebugLog("browser.stop panel=\(panel.id.uuidString.prefix(5))")
#endif
            panel.stopLoading()
            return
        }

        if panel.recoverTerminatedWebContent(reason: "toolbarReload") {
            return
        }

        if currentEventIsCommandPointerActivation {
#if DEBUG
            cmuxDebugLog("browser.reload.commandClickDuplicate panel=\(panel.id.uuidString.prefix(5))")
#endif
            guard let workspace = owningWorkspace else {
#if DEBUG
                cmuxDebugLog("browser.reload.commandClickDuplicate.abort panel=\(panel.id.uuidString.prefix(5)) reason=workspaceMissing")
#endif
                return
            }
            guard let newPanel = workspace.duplicateBrowserToRight(panelId: panel.id) else {
#if DEBUG
                cmuxDebugLog("browser.reload.commandClickDuplicate.abort panel=\(panel.id.uuidString.prefix(5)) reason=newPanelFailed")
#endif
                return
            }
#if DEBUG
            cmuxDebugLog(
                "browser.reload.commandClickDuplicate.done panel=\(panel.id.uuidString.prefix(5)) " +
                "newPanel=\(newPanel.id.uuidString.prefix(5))"
            )
#endif
            return
        }

#if DEBUG
        cmuxDebugLog("browser.reload panel=\(panel.id.uuidString.prefix(5))")
#endif
        panel.reload()
    }

    func handleScreenshotPageButtonAction() {
        guard !screenshotPageCaptureInProgress else { return }
        screenshotPageCaptureInProgress = true
#if DEBUG
        cmuxDebugLog("browser.screenshot.page.toolbar panel=\(panel.id.uuidString.prefix(5))")
#endif
        Task { @MainActor in
            defer {
                screenshotPageCaptureInProgress = false
            }
            let didCopy = await panel.captureScreenshotPageToClipboard()
            guard didCopy else { return }
            showScreenshotPageCopiedIndicator()
        }
    }

    private func showScreenshotPageCopiedIndicator() {
        screenshotPageCopiedTimer?.invalidate()
        screenshotPageCopied = true
        screenshotPageCopiedTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { _ in
            MainActor.assumeIsolated {
                screenshotPageCopiedTimer = nil
                screenshotPageCopied = false
            }
        }
    }

    func handleBrowserFocusModeButtonAction() {
        if !panel.toggleBrowserFocusMode(reason: "toolbarButton", focusWebView: true) {
            NSSound.beep()
        }
    }

    var browserFocusModeButtonHelp: String {
        let format = String(localized: "browser.focusMode.helpWithShortcut.format", defaultValue: "%@ (%@)")
        if panel.isBrowserFocusModeActive {
            let title = String(localized: "browser.focusMode.exit.help", defaultValue: "Exit browser focus mode")
            // Active: show the double-Escape exit hint.
            return String(format: format, title, browserFocusModeShortcutHint)
        }
        let title = String(localized: "browser.focusMode.enter.help", defaultValue: "Enter browser focus mode")
        // Inactive: show the configured enter shortcut, if one is bound.
        guard let enterHint = browserFocusModeEnterShortcutHint else { return title }
        return String(format: format, title, enterHint)
    }

    var browserFocusModeShortcutHint: String {
        String(localized: "browser.focusMode.shortcutHint", defaultValue: "Esc Esc")
    }

    private var browserFocusModeEnterShortcutHint: String? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .toggleBrowserFocusMode)
        guard !shortcut.isUnbound else { return nil }
        return shortcut.displayString
    }

    var shouldShowBrowserFocusModeShortcutHint: Bool {
        panel.isBrowserFocusModeActive &&
            panel.canToggleBrowserFocusMode &&
            (ShortcutHintDebugSettings.alwaysShowHints() || focusModeShortcutHintMonitor.isModifierPressed)
    }

    func openDevTools() {
        #if DEBUG
        cmuxDebugLog("browser.toggleDevTools panel=\(panel.id.uuidString.prefix(5))")
        #endif
        if !panel.toggleDeveloperTools() {
            NSSound.beep()
        }
    }

    func applyBrowserThemeModeSelection(_ mode: BrowserThemeMode) {
        if browserThemeModeRaw != mode.rawValue {
            browserThemeModeRaw = mode.rawValue
        }
        panel.setBrowserThemeMode(mode)
    }

    func applyBrowserProfileSelection(_ profileID: UUID) {
        isBrowserProfileMenuPresented = false
        let didApply = panel.profileID == profileID || panel.switchToProfile(profileID)
        guard didApply else { return }
        owningWorkspace?.setPreferredBrowserProfileID(profileID)
    }

    func presentCreateBrowserProfilePrompt() {
        let alert = NSAlert()
        alert.messageText = String(localized: "browser.profile.new.title", defaultValue: "New Browser Profile")
        alert.informativeText = String(localized: "browser.profile.new.message", defaultValue: "Create a separate browser profile for cookies, history, and local storage.")

        let input = NSTextField(string: "")
        input.placeholderString = String(localized: "browser.profile.new.placeholder", defaultValue: "Profile name")
        input.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = input

        alert.addButton(withTitle: String(localized: "common.create", defaultValue: "Create"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        guard alert.runModal() == .alertFirstButtonReturn,
              let profile = browserProfileStore.createProfile(named: input.stringValue) else {
            return
        }

        applyBrowserProfileSelection(profile.id)
    }

    func presentRenameBrowserProfilePrompt() {
        guard let profile = browserProfileStore.profileDefinition(id: panel.profileID),
              browserProfileStore.canRenameProfile(id: profile.id) else {
            return
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "browser.profile.rename.title", defaultValue: "Rename Browser Profile")
        alert.informativeText = String(localized: "browser.profile.rename.message", defaultValue: "Choose a new name for this browser profile.")

        let input = NSTextField(string: profile.displayName)
        input.placeholderString = String(localized: "browser.profile.new.placeholder", defaultValue: "Profile name")
        input.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = input

        alert.addButton(withTitle: String(localized: "common.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = browserProfileStore.renameProfile(id: profile.id, to: input.stringValue)
    }

}
