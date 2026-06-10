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


// MARK: - Command palette visibility and focus routing
extension AppDelegate {
    func markCommandPaletteOpenRequested(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPalettePendingOpenByWindowId[windowId] = true
        commandPaletteRecentRequestAtByWindowId[windowId] = ProcessInfo.processInfo.systemUptime
    }

    private func postCommandPaletteRequest(
        name: Notification.Name,
        preferredWindow: NSWindow?,
        source: String,
        markPending: Bool
    ) {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        if let targetWindow,
           let context = contextForMainWindow(targetWindow) {
            _ = context.tabManager.setFocusedBrowserFocusModeActive(false, reason: "commandPaletteRequest.\(source)")
        }
        if markPending {
            markCommandPaletteOpenRequested(for: targetWindow)
        }
        NotificationCenter.default.post(name: name, object: targetWindow)
#if DEBUG
        cmuxDebugLog(
            "shortcut.palette.request source=\(source) " +
            "target={\(debugWindowToken(targetWindow))} " +
            "pendingMarked=\(markPending ? 1 : 0)"
        )
#endif
    }

    func requestCommandPaletteCommands(preferredWindow: NSWindow? = nil, source: String = "api.commandPalette") {
        postCommandPaletteRequest(
            name: .commandPaletteRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    func requestCommandPaletteSwitcher(preferredWindow: NSWindow? = nil, source: String = "api.commandPaletteSwitcher") {
        postCommandPaletteRequest(
            name: .commandPaletteSwitcherRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    func requestCommandPaletteRenameTab(preferredWindow: NSWindow? = nil, source: String = "api.commandPaletteRenameTab") {
        postCommandPaletteRequest(
            name: .commandPaletteRenameTabRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    func requestCommandPaletteRenameWorkspace(
        preferredWindow: NSWindow? = nil,
        source: String = "api.commandPaletteRenameWorkspace"
    ) {
        postCommandPaletteRequest(
            name: .commandPaletteRenameWorkspaceRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    func requestCommandPaletteEditWorkspaceDescription(
        preferredWindow: NSWindow? = nil,
        source: String = "api.commandPaletteEditWorkspaceDescription"
    ) {
        postCommandPaletteRequest(
            name: .commandPaletteEditWorkspaceDescriptionRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    func clearCommandPalettePendingOpen(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPalettePendingOpenByWindowId.removeValue(forKey: windowId)
        commandPaletteRecentRequestAtByWindowId.removeValue(forKey: windowId)
    }

    private func pruneExpiredCommandPalettePendingOpenStates(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        for windowId in Array(commandPalettePendingOpenByWindowId.keys) {
            guard commandPalettePendingOpenByWindowId[windowId] == true else { continue }
            guard let requestedAt = commandPaletteRecentRequestAtByWindowId[windowId] else {
                commandPalettePendingOpenByWindowId.removeValue(forKey: windowId)
#if DEBUG
                cmuxDebugLog("shortcut.palette.pendingPrune windowId=\(windowId.uuidString.prefix(8)) reason=missingTimestamp")
#endif
                continue
            }
            let age = now - requestedAt
            guard age > Self.commandPalettePendingOpenMaxAge else { continue }
            commandPalettePendingOpenByWindowId.removeValue(forKey: windowId)
            commandPaletteRecentRequestAtByWindowId.removeValue(forKey: windowId)
#if DEBUG
            cmuxDebugLog(
                "shortcut.palette.pendingPrune windowId=\(windowId.uuidString.prefix(8)) " +
                "reason=stale ageMs=\(Int(age * 1000))"
            )
#endif
        }
    }

    func isCommandPalettePendingOpen(for window: NSWindow) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        pruneExpiredCommandPalettePendingOpenStates()
        return commandPalettePendingOpenByWindowId[windowId] == true
    }

    func beginCommandPaletteEscapeSuppression(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPaletteEscapeSuppressionByWindowId.insert(windowId)
        commandPaletteEscapeSuppressionStartedAtByWindowId[windowId] = ProcessInfo.processInfo.systemUptime
    }

    private func endCommandPaletteEscapeSuppression(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPaletteEscapeSuppressionByWindowId.remove(windowId)
        commandPaletteEscapeSuppressionStartedAtByWindowId.removeValue(forKey: windowId)
    }

    func shouldConsumeSuppressedEscape(event: NSEvent, window: NSWindow?) -> Bool {
        guard let window,
              let windowId = mainWindowId(for: window),
              commandPaletteEscapeSuppressionByWindowId.contains(windowId) else {
            return false
        }
        let startedAt = commandPaletteEscapeSuppressionStartedAtByWindowId[windowId] ?? 0
        if ProcessInfo.processInfo.systemUptime - startedAt <= 0.35 {
            return true
        }
        // Fallback cleanup when keyUp is lost for any reason.
        endCommandPaletteEscapeSuppression(for: window)
        return false
    }

    func recentCommandPaletteRequestAge(for window: NSWindow?) -> TimeInterval? {
        guard let window,
              let windowId = mainWindowId(for: window) else {
            return nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        pruneExpiredCommandPalettePendingOpenStates(now: now)
        guard commandPalettePendingOpenByWindowId[windowId] == true else {
            commandPaletteRecentRequestAtByWindowId.removeValue(forKey: windowId)
            return nil
        }
        guard let startedAt = commandPaletteRecentRequestAtByWindowId[windowId] else {
            commandPalettePendingOpenByWindowId.removeValue(forKey: windowId)
            return nil
        }
        let age = now - startedAt
        if age <= Self.commandPaletteRequestGraceInterval {
            return age
        }
        return nil
    }

    private func escapeSuppressionWindow(for event: NSEvent) -> NSWindow? {
        commandPaletteWindowForShortcutEvent(event) ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    @discardableResult
    func clearEscapeSuppressionForKeyUp(event: NSEvent, consumeIfSuppressed: Bool = false) -> Bool {
        guard event.type == .keyUp, event.keyCode == 53 else { return false }
        let suppressionWindow = escapeSuppressionWindow(for: event)
        let didConsume = consumeIfSuppressed && shouldConsumeSuppressedEscape(event: event, window: suppressionWindow)
        if let window = suppressionWindow {
            endCommandPaletteEscapeSuppression(for: window)
#if DEBUG
            cmuxDebugLog(
                "shortcut.escape suppressionClear target={\(debugWindowToken(window))} " +
                "keyUpConsumed=\(didConsume ? 1 : 0)"
            )
#endif
            return didConsume
        }
        commandPaletteEscapeSuppressionByWindowId.removeAll()
        commandPaletteEscapeSuppressionStartedAtByWindowId.removeAll()
#if DEBUG
        cmuxDebugLog("shortcut.escape suppressionClear target={nil} clearedAll=1 keyUpConsumed=\(didConsume ? 1 : 0)")
#endif
        return didConsume
    }

    func setCommandPaletteVisible(_ visible: Bool, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        if visible, let context = contextForMainWindow(window) {
            _ = context.tabManager.setFocusedBrowserFocusModeActive(false, reason: "commandPaletteVisible")
        }
        let wasVisible = commandPaletteVisibilityByWindowId.updateValue(visible, forKey: windowId) ?? false
        postCommandPaletteVisibilityDidChangeIfNeeded(wasVisible: wasVisible, visible: visible, window: window, windowId: windowId)
        // Opening (false -> true) always resolves pending-open.
        // Closing (true -> false) also clears stale pending state.
        // Ignore repeated false updates so a stale sync cannot erase an in-flight open request.
        if visible || wasVisible {
            commandPalettePendingOpenByWindowId.removeValue(forKey: windowId)
            commandPaletteRecentRequestAtByWindowId.removeValue(forKey: windowId)
        }
#if DEBUG
        if !visible,
           !wasVisible,
           commandPalettePendingOpenByWindowId[windowId] == true {
            cmuxDebugLog(
                "palette.visibility.retainPending " +
                "window={\(debugWindowToken(window))} visible=0 wasVisible=0 pending=1"
            )
        }
#endif
    }

    func isCommandPaletteVisible(windowId: UUID) -> Bool {
        commandPaletteVisibilityByWindowId[windowId] ?? false
    }

    func setCommandPaletteSelectionIndex(_ index: Int, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        commandPaletteSelectionByWindowId[windowId] = max(0, index)
    }

    func commandPaletteSelectionIndex(windowId: UUID) -> Int {
        commandPaletteSelectionByWindowId[windowId] ?? 0
    }

    func setCommandPaletteSnapshot(_ snapshot: CommandPaletteDebugSnapshot, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        commandPaletteSnapshotByWindowId[windowId] = snapshot
    }

    func commandPaletteSnapshot(windowId: UUID) -> CommandPaletteDebugSnapshot {
        commandPaletteSnapshotByWindowId[windowId] ?? .empty
    }

    func isCommandPaletteVisible(for window: NSWindow) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        return commandPaletteVisibilityByWindowId[windowId] ?? false
    }

    func isCommandPaletteEffectivelyVisible(for window: NSWindow) -> Bool {
        isCommandPaletteEffectivelyVisible(in: window)
    }

    func shouldBlockFirstResponderChangeWhileCommandPaletteVisible(
        window: NSWindow,
        responder: NSResponder?
    ) -> Bool {
        guard isCommandPaletteVisible(for: window) else { return false }
        guard let responder else { return false }
        guard !isCommandPaletteResponder(responder) else { return false }
        return isFocusStealingResponderWhileCommandPaletteVisible(responder)
    }

    private func isCommandPaletteResponder(_ responder: NSResponder) -> Bool {
        if let textView = responder as? NSTextView, textView.isFieldEditor {
            if let delegateView = textView.delegate as? NSView {
                return isInsideCommandPaletteOverlay(delegateView)
            }
            // SwiftUI can attach a non-view delegate to TextField editors.
            // When command palette is visible, its search/rename editor is the
            // only expected field editor inside the main window.
            return true
        }
        if let view = responder as? NSView {
            return isInsideCommandPaletteOverlay(view)
        }
        return false
    }

    private func isFocusStealingResponderWhileCommandPaletteVisible(_ responder: NSResponder) -> Bool {
        isCommandPaletteFocusStealingTerminalOrBrowserResponder(responder)
    }

    private func isInsideCommandPaletteOverlay(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    func keyRoutingOwnerView(for responder: NSResponder?) -> NSView? {
        guard let responder else { return nil }
        if let editor = responder as? NSTextView,
           editor.isFieldEditor {
            return cmuxFieldEditorOwnerView(editor) ?? editor
        }
        return responder as? NSView
    }

    private func responderHasViableKeyRoutingOwner(
        _ responder: NSResponder,
        in window: NSWindow
    ) -> Bool {
        if let ghosttyView = cmuxOwningGhosttyView(for: responder) {
            if ghosttyView.window !== window {
                return false
            }
            if ghosttyView.isHiddenOrHasHiddenAncestor {
                return false
            }
            return ghosttyView === window.contentView || ghosttyView.superview != nil
        }

        guard let ownerView = keyRoutingOwnerView(for: responder) else {
            return false
        }

        if ownerView.window !== window {
            return false
        }

        if ownerView.isHiddenOrHasHiddenAncestor {
            return false
        }

        if ownerView !== window.contentView, ownerView.superview == nil {
            return false
        }

        return true
    }

    private func responderNeedsFocusedTerminalKeyRepair(
        _ responder: NSResponder?,
        in window: NSWindow,
        hostedView: GhosttySurfaceScrollView
    ) -> Bool {
        guard let responder else { return true }
        if isRightSidebarFocusResponder(responder, in: window) {
            return false
        }
        return focusedTerminalKeyRepairNeeded(
            responderIsWindow: responder is NSWindow,
            responderHasViableKeyRoutingOwner: responderHasViableKeyRoutingOwner(responder, in: window),
            responderMatchesPreferredKeyboardFocus: hostedView.responderMatchesPreferredKeyboardFocus(responder)
        )
    }

    func repairFocusedTerminalKeyboardRoutingIfNeeded(
        window: NSWindow,
        event: NSEvent
    ) {
        guard event.type == .keyDown else { return }
        let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard isMainTerminalWindow(window) else { return }
        guard window.attachedSheet == nil else { return }
        guard !isCommandPaletteEffectivelyVisible(in: window) else { return }
        // If the active first responder is owned by a non-terminal interaction surface,
        // never re-route the keystroke to the terminal. Symmetric with
        // applyFirstResponderIfNeeded's foreign focus guard.
        if let firstResponder = window.firstResponder,
           shouldRespectForeignFirstResponder(firstResponder, in: window, isRightSidebarOwner: {
               isRightSidebarFocusResponder($0, in: window)
           }) {
            return
        }
        guard let context = contextForMainWindow(window) ?? contextForMainTerminalWindow(window),
              let workspace = context.tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            return
        }
        let firstResponder = window.firstResponder
        if normalizedFlags.contains(.command) {
            let responderHasViableOwner = firstResponder.map { responderHasViableKeyRoutingOwner($0, in: window) } ?? false
            let commandEquivalentNeedsRepair = shouldRepairFocusedTerminalCommandEquivalentInputs(
                flags: normalizedFlags,
                responderIsWindow: firstResponder is NSWindow,
                responderHasViableKeyRoutingOwner: responderHasViableOwner
            )
            guard commandEquivalentNeedsRepair else { return }
        } else {
            guard responderNeedsFocusedTerminalKeyRepair(
                firstResponder,
                in: window,
                hostedView: terminalPanel.hostedView
            ) else { return }
        }

#if DEBUG
        let before = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let target = terminalPanel.hostedView.preferredPanelFocusIntentForActivation()
        let targetLabel: String = {
            switch target {
            case .surface:
                return "surface"
            case .findField:
                return "searchField"
            case .textBoxInput:
                return "textBoxInput"
            }
        }()
        let mode = normalizedFlags.contains(.command) ? "command" : "plain"
        cmuxDebugLog(
            "focus.keyRepair attempt window=\(ObjectIdentifier(window)) " +
            "workspace=\(String(workspace.id.uuidString.prefix(5))) " +
            "panel=\(String(panelId.uuidString.prefix(5))) " +
            "mode=\(mode) " +
            "target=\(targetLabel) " +
            "fr=\(before) keyCode=\(event.keyCode) mods=\(event.modifierFlags.rawValue)"
        )
#endif

        terminalPanel.hostedView.ensureFocus(for: workspace.id, surfaceId: panelId)

#if DEBUG
        let after = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        cmuxDebugLog(
            "focus.keyRepair result window=\(ObjectIdentifier(window)) " +
            "panel=\(String(panelId.uuidString.prefix(5))) " +
            "isSurfaceResponder=\(terminalPanel.hostedView.isSurfaceViewFirstResponder() ? 1 : 0) " +
            "fr=\(after)"
        )
#endif
    }

    private func commandPaletteOverlayContainer(in window: NSWindow) -> NSView? {
        guard let searchRoot = window.contentView?.superview ?? window.contentView else { return nil }
        var stack: [NSView] = [searchRoot]
        while let candidate = stack.popLast() {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return candidate
            }
            stack.append(contentsOf: candidate.subviews)
        }
        return nil
    }

    func isCommandPaletteOverlayPresented(in window: NSWindow) -> Bool {
        guard let container = commandPaletteOverlayContainer(in: window) else { return false }
        return !container.isHidden && container.alphaValue > 0.001
    }

    func isCommandPaletteResponderActive(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if let textView = responder as? NSTextView,
           textView.isFieldEditor,
           !(textView.delegate is NSView) {
            // Field-editor delegates can be non-view responders. Confirm the overlay is
            // mounted and visible to avoid treating unrelated editors as palette input.
            return isCommandPaletteOverlayPresented(in: window)
        }
        return isCommandPaletteResponder(responder)
    }

    func isCommandPaletteMultilineTextResponderActive(in window: NSWindow) -> Bool {
        guard let textView = window.firstResponder as? NSTextView,
              !textView.isFieldEditor else {
            return false
        }
        return isCommandPaletteResponder(textView)
    }

    func commandPaletteMarkedTextInput(in window: NSWindow) -> NSTextView? {
        if let textView = window.firstResponder as? NSTextView,
           isCommandPaletteResponder(textView),
           textView.hasMarkedText() {
            return textView
        }

        if let textField = window.firstResponder as? NSTextField,
           let editor = textField.currentEditor() as? NSTextView,
           isCommandPaletteResponder(editor),
           editor.hasMarkedText() {
            return editor
        }

        return nil
    }

    func isCommandPaletteEffectivelyVisible(in window: NSWindow) -> Bool {
        isCommandPaletteVisible(for: window)
            || isCommandPalettePendingOpen(for: window)
            || isCommandPaletteOverlayPresented(in: window)
            || isCommandPaletteResponderActive(in: window)
    }

    func activeCommandPaletteWindow() -> NSWindow? {
        pruneExpiredCommandPalettePendingOpenStates()
        if let keyWindow = NSApp.keyWindow,
           isMainTerminalWindow(keyWindow),
           isCommandPaletteEffectivelyVisible(in: keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow,
           isMainTerminalWindow(mainWindow),
           isCommandPaletteEffectivelyVisible(in: mainWindow) {
            return mainWindow
        }
        if let orderedWindow = NSApp.orderedWindows.first(where: { window in
            isMainTerminalWindow(window) && isCommandPaletteEffectivelyVisible(in: window)
        }) {
            return orderedWindow
        }
        if let visibleWindowId = commandPaletteVisibilityByWindowId.first(where: { $0.value })?.key {
            return windowForMainWindowId(visibleWindowId)
        }
        if let pendingWindowId = commandPalettePendingOpenByWindowId.first(where: { $0.value })?.key {
            return windowForMainWindowId(pendingWindowId)
        }
        return nil
    }

    func commandPaletteWindowForShortcutEvent(_ event: NSEvent) -> NSWindow? {
        if let scopedWindow = mainWindowForShortcutEvent(event) {
            return scopedWindow
        }
        return activeCommandPaletteWindow()
    }

}
