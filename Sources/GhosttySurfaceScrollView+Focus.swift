import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers


// MARK: - Focus management and panel focus intents
extension GhosttySurfaceScrollView {
    func setFocusHandler(_ handler: (() -> Void)?) {
        guard let handler else {
            surfaceView.onFocus = nil
            return
        }
        surfaceView.onFocus = { [weak self] in
            // When the terminal surface gains focus (click, tab, etc.), update the
            // search focus target so window reactivation restores terminal focus.
            if self?.surfaceView.terminalSurface?.searchState != nil {
                self?.searchFocusTarget = .terminal
            }
            handler()
        }
    }

    func beginFindEscapeSuppression() {
        surfaceView.beginFindEscapeSuppression()
    }

    func moveFocus(from previous: GhosttySurfaceScrollView? = nil, delay: TimeInterval? = nil) {
#if DEBUG
        let surfaceShort = String(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
        let searchActive = self.surfaceView.terminalSurface?.searchState != nil
        cmuxDebugLog(
            "find.moveFocus to=\(surfaceShort) " +
            "from=\(previous?.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "searchState=\(searchActive ? "active" : "nil") " +
            "delayMs=\(Int((delay ?? 0) * 1000))"
        )
#endif
        let work = { [weak self] in
            guard let self else { return }
            guard let window = self.uiWindow else { return }
#if DEBUG
            let before = String(describing: window.firstResponder)
#endif
            guard self.canRequestSurfaceFirstResponder(in: window, reason: "moveFocus") else { return }
            if let previous, previous !== self {
                _ = previous.surfaceView.resignFirstResponder()
            }
            let result = window.makeFirstResponder(self.surfaceView)
#if DEBUG
            cmuxDebugLog(
                "find.moveFocus.apply to=\(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "result=\(result ? 1 : 0) before=\(before) after=\(String(describing: window.firstResponder))"
            )
#endif
        }

        if let delay, delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
        } else {
            if Thread.isMainThread {
                work()
            } else {
                DispatchQueue.main.async { work() }
            }
        }
    }

#if DEBUG
    /// Sends a synthetic key press/release pair directly to the surface view.
    /// This exercises the same key path as real keyboard input (ghostty_surface_key),
    /// unlike sendText, which bypasses key translation.
    @discardableResult
    func debugSendSyntheticKeyPressAndReleaseForUITest(
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> Bool {
        guard let window = uiWindow else { return false }
        window.makeFirstResponder(surfaceView)

        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let keyDown = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else { return false }

        guard let keyUp = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else { return false }

        surfaceView.keyDown(with: keyDown)
        surfaceView.keyUp(with: keyUp)
        return true
    }

    /// Sends a synthetic Ctrl+D key press directly to the surface view.
    /// This exercises the same key path as real keyboard input (ghostty_surface_key),
    /// unlike `sendText`, which bypasses key translation.
    @discardableResult
    func sendSyntheticCtrlDForUITest(modifierFlags: NSEvent.ModifierFlags = [.control]) -> Bool {
        debugSendSyntheticKeyPressAndReleaseForUITest(
            characters: "\u{04}",
            charactersIgnoringModifiers: "d",
            keyCode: 2,
            modifierFlags: modifierFlags
        )
    }
    #endif

    func ensureFocus(
        for tabId: UUID,
        surfaceId: UUID,
        respectForeignFirstResponder: Bool = true
    ) {
        let hasUsablePortalGeometry: Bool = {
            let size = bounds.size
            return size.width > 1 && size.height > 1
        }()
        let isHiddenForFocus = isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor

        guard isActive else { return }
        guard let window = uiWindow else { return }
        guard surfaceView.isVisibleInUI else {
#if DEBUG
            cmuxDebugLog(
                "focus.ensure.defer surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "reason=not_visible"
            )
#endif
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.notVisible")
            return
        }
        guard !isHiddenForFocus, hasUsablePortalGeometry else {
#if DEBUG
            cmuxDebugLog(
                "focus.ensure.defer surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "reason=hidden_or_tiny hidden=\(isHiddenForFocus ? 1 : 0) " +
                "frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height))"
            )
#endif
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.hiddenOrTiny")
            return
        }

        if let terminalSurface = surfaceView.terminalSurface,
           terminalSurface.focusPlacement == .rightSidebarDock {
            guard AppDelegate.shared?.allowsTerminalKeyboardFocus(
                workspaceId: tabId,
                panelId: surfaceId,
                in: window
            ) != false else {
#if DEBUG
                dlog("focus.ensure.skip surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") reason=dockCoordinator")
#endif
                return
            }
            if terminalSurface.searchState != nil {
#if DEBUG
                cmuxDebugLog(
                    "focus.ensure.dock.search surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                    "tab=\(tabId.uuidString.prefix(5)) panel=\(surfaceId.uuidString.prefix(5)) " +
                    "firstResponder=\(String(describing: window.firstResponder))"
                )
#endif
                restoreSearchFocus(window: window)
                return
            }
            if let fr = window.firstResponder as? NSView,
               fr === surfaceView || fr.isDescendant(of: surfaceView) {
                reassertTerminalSurfaceFocus(reason: "ensureFocus.dock.alreadyFirstResponder")
                return
            }
            if respectForeignFirstResponder,
               let firstResponder = window.firstResponder,
               shouldRespectForeignFirstResponder(firstResponder, in: window, isRightSidebarOwner: {
               AppDelegate.shared?.isRightSidebarFocusResponder($0, in: window) == true
           }) {
#if DEBUG
                let reason = firstResponder is NSText ? "textEditorFocused" : "rightSidebarFocused"
                dlog("focus.ensure.skip surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") reason=dock.\(reason)")
#endif
                return
            }
            let result = window.makeFirstResponder(surfaceView)
#if DEBUG
            cmuxDebugLog(
                "focus.ensure.dock.apply surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "result=\(result ? 1 : 0) firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
            if isSurfaceViewFirstResponder() {
                reassertTerminalSurfaceFocus(reason: "ensureFocus.dock.afterMakeFirstResponder")
            }
            return
        }

        guard let delegate = AppDelegate.shared,
              let tabManager = delegate.tabManagerFor(tabId: tabId) ?? delegate.tabManager,
              tabManager.selectedTabId == tabId else {
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.inactiveTab")
            return
        }

        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              let tabIdForSurface = tab.surfaceIdFromPanelId(surfaceId),
              let paneId = tab.bonsplitController.allPaneIds.first(where: { paneId in
                  tab.bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabIdForSurface })
              }) else {
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.missingPane")
            return
        }

        guard tab.bonsplitController.selectedTab(inPane: paneId)?.id == tabIdForSurface,
              tab.bonsplitController.focusedPaneId == paneId else {
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.unfocusedPane")
            return
        }

        guard delegate.allowsTerminalKeyboardFocus(workspaceId: tabId, panelId: surfaceId, in: window) else {
#if DEBUG
            dlog("focus.ensure.skip surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") reason=coordinatorRightSidebar")
#endif
            return
        }

        // Search focus restoration — only after confirming this is the active tab/pane.
        if surfaceView.terminalSurface?.searchState != nil {
#if DEBUG
            cmuxDebugLog(
                "focus.ensure.search surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "tab=\(tabId.uuidString.prefix(5)) panel=\(surfaceId.uuidString.prefix(5)) " +
                "firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
            restoreSearchFocus(window: window)
            return
        }

        if let fr = window.firstResponder as? NSView,
           fr === surfaceView || fr.isDescendant(of: surfaceView) {
            reassertTerminalSurfaceFocus(reason: "ensureFocus.alreadyFirstResponder")
            return
        }

        // Layout and visibility reconciliation can ask the active terminal to
        // reassert focus after a sidebar/text owner has already accepted focus.
        // Respect those explicit AppKit first responders unless the terminal
        // surface already owns focus.
        if respectForeignFirstResponder,
           let firstResponder = window.firstResponder,
           shouldRespectForeignFirstResponder(firstResponder, in: window, isRightSidebarOwner: {
               AppDelegate.shared?.isRightSidebarFocusResponder($0, in: window) == true
           }) {
#if DEBUG
            let reason = firstResponder is NSText ? "textEditorFocused" : "rightSidebarFocused"
            dlog("focus.ensure.skip surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") reason=\(reason)")
#endif
            return
        }

        if !window.isKeyWindow {
            guard shouldAllowEnsureFocusWindowActivation(
                activeTabManager: delegate.tabManager,
                targetTabManager: tabManager,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow,
                targetWindow: window
            ) else {
                return
            }
            window.makeKeyAndOrderFront(nil)
        }
        let result = window.makeFirstResponder(surfaceView)
#if DEBUG
        cmuxDebugLog(
            "focus.ensure.apply surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "tab=\(tabId.uuidString.prefix(5)) panel=\(surfaceId.uuidString.prefix(5)) " +
            "result=\(result ? 1 : 0) firstResponder=\(String(describing: window.firstResponder))"
        )
#endif

        if !isSurfaceViewFirstResponder() {
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.afterMakeFirstResponder")
        } else {
            reassertTerminalSurfaceFocus(reason: "ensureFocus.afterMakeFirstResponder")
        }
    }

    func yieldTerminalSurfaceFocusForForeignResponder(reason: String) {
        surfaceView.desiredFocus = false
        guard let terminalSurface = surfaceView.terminalSurface else { return }
        terminalSurface.setFocus(false)
#if DEBUG
        dlog("focus.surface.yield surface=\(terminalSurface.id.uuidString.prefix(5)) reason=\(reason)")
#endif
        terminalSurface.forceRefresh(reason: "focus.surface.\(reason)")
    }

    func matchesCurrentTerminalFocusTarget(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let delegate = AppDelegate.shared,
              let tabManager = delegate.tabManagerFor(tabId: tabId) ?? delegate.tabManager,
              tabManager.selectedTabId == tabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              let tabIdForSurface = tab.surfaceIdFromPanelId(surfaceId),
              let paneId = tab.bonsplitController.allPaneIds.first(where: { paneId in
                  tab.bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabIdForSurface })
              }) else {
            return false
        }

        return tab.bonsplitController.selectedTab(inPane: paneId)?.id == tabIdForSurface &&
            tab.bonsplitController.focusedPaneId == paneId
    }

    /// Suppress the surface view's onFocus callback and ghostty_surface_set_focus during
    /// SwiftUI reparenting (programmatic splits). Call clearSuppressReparentFocus() after layout settles.
    func suppressReparentFocus() {
        surfaceView.suppressingReparentFocus = true
    }

    func isSuppressingReparentFocusForLayoutFollowUp() -> Bool {
        surfaceView.suppressingReparentFocus
    }

    func canClearPendingReparentFocusSuppressionAfterLayoutAttempt() -> Bool {
        // After Workspace has flushed a layout follow-up, the protected reparent
        // turn has passed even if AppKit never tried to focus this old view.
        true
    }

    func clearReparentFocusSuppressionForPointerFocus() {
        guard surfaceView.suppressingReparentFocus else { return }
        surfaceView.suppressingReparentFocus = false
#if DEBUG
        cmuxDebugLog("focus.reparent.pointerClear surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
    }

    func clearSuppressReparentFocus() {
        surfaceView.suppressingReparentFocus = false
        let hasUsablePortalGeometry: Bool = {
            let size = bounds.size
            return size.width > 1 && size.height > 1
        }()
        let isHiddenForFocus = isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor
        let surfaceShort = String(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
        let surfaceOwnsFirstResponder = currentTerminalSurfaceOwnsFirstResponder()

        guard surfaceView.desiredFocus || surfaceOwnsFirstResponder else { return }
        guard surfaceView.isVisibleInUI else { return }
        surfaceView.terminalSurface?.recordExternalFocusState(true)
        guard let window = uiWindow, window.isKeyWindow else { return }
        guard !isHiddenForFocus, hasUsablePortalGeometry else {
#if DEBUG
            cmuxDebugLog(
                "focus.reparent.resume.defer surface=\(surfaceShort) " +
                "reason=hidden_or_tiny hidden=\(isHiddenForFocus ? 1 : 0) " +
                "frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height))"
            )
#endif
            scheduleAutomaticFirstResponderApply(reason: "clearSuppressReparentFocus.hiddenOrTiny")
            return
        }
        if !surfaceOwnsFirstResponder && !isSurfaceViewFirstResponder() {
#if DEBUG
            cmuxDebugLog(
                "focus.reparent.resume.restoreFirstResponder surface=\(surfaceShort) " +
                "firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
            guard requestSurfaceFirstResponder(in: window, reason: "clearSuppressReparentFocus"),
                  isSurfaceViewFirstResponder() else { return }
        }
#if DEBUG
        cmuxDebugLog("focus.reparent.resume surface=\(surfaceShort) firstResponder=\(String(describing: window.firstResponder))")
#endif
        reassertTerminalSurfaceFocus(reason: "clearSuppressReparentFocus", force: true)
    }

    /// Returns true if the terminal's actual Ghostty surface view is (or contains) the window first responder.
    /// This is stricter than checking `hostedView` descendants, since the scroll view can sometimes become
    /// first responder transiently while focus is being applied.
    func isSurfaceViewFirstResponder() -> Bool {
        guard let window = uiWindow, let fr = window.firstResponder as? NSView else { return false }
        return fr === surfaceView || fr.isDescendant(of: surfaceView)
    }

#if DEBUG
    func debugIsSuppressingReparentFocusForTesting() -> Bool {
        surfaceView.suppressingReparentFocus
    }
#endif

    private func currentTerminalSurfaceOwnsFirstResponder() -> Bool {
        guard let window = uiWindow, let firstResponder = window.firstResponder as? NSView else { return false }
        if firstResponder === surfaceView || firstResponder.isDescendant(of: surfaceView) {
            return true
        }
        guard let terminalSurface = surfaceView.terminalSurface else { return false }
        var current: NSView? = firstResponder
        while let view = current {
            if let ghosttyView = view as? GhosttyNSView,
               ghosttyView.terminalSurface === terminalSurface {
                return true
            }
            current = view.superview
        }
        return false
    }

    private func canRequestSurfaceFirstResponder(in window: NSWindow, reason: String) -> Bool {
        guard let terminalSurface = surfaceView.terminalSurface else {
            return true
        }
        let allowed = AppDelegate.shared?.allowsTerminalKeyboardFocus(
            workspaceId: terminalSurface.tabId,
            panelId: terminalSurface.id,
            in: window
        ) ?? true
#if DEBUG
        if !allowed {
            dlog(
                "focus.apply.skip surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "reason=\(reason).coordinatorRightSidebar"
            )
        }
#endif
        return allowed
    }

    @discardableResult
    func requestSurfaceFirstResponder(in window: NSWindow, reason: String) -> Bool {
        guard canRequestSurfaceFirstResponder(in: window, reason: reason) else {
            return false
        }
        return window.makeFirstResponder(surfaceView)
    }

    func scheduleAutomaticFirstResponderApply(reason: String) {
        guard !pendingAutomaticFirstResponderApply else { return }
        pendingAutomaticFirstResponderApply = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingAutomaticFirstResponderApply = false
#if DEBUG
            let surfaceShort = String(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
            cmuxDebugLog("find.applyFirstResponder.defer surface=\(surfaceShort) reason=\(reason)")
#endif
            self.applyFirstResponderIfNeeded()
        }
    }

    private func reassertTerminalSurfaceFocus(reason: String, force: Bool = false) {
        guard let terminalSurface = surfaceView.terminalSurface else { return }
        if terminalSurface.surface == nil {
            terminalSurface.requestBackgroundSurfaceStartIfNeeded()
        }
#if DEBUG
        cmuxDebugLog("focus.surface.reassert surface=\(terminalSurface.id.uuidString.prefix(5)) reason=\(reason)")
#endif
        terminalSurface.setFocus(true, force: force)
        refreshSurfaceAfterFocusIfNeeded(reason: reason)
    }

    private func refreshSurfaceAfterFocusIfNeeded(reason: String) {
        guard let terminalSurface = surfaceView.terminalSurface,
              isActive,
              let window = uiWindow,
              window.isKeyWindow,
              surfaceView.isVisibleInUI else { return }

        let now = CACurrentMediaTime()
        if now - lastFocusRefreshAt < 0.05 {
            return
        }
        lastFocusRefreshAt = now
#if DEBUG
        cmuxDebugLog("focus.surface.refresh surface=\(terminalSurface.id.uuidString.prefix(5)) reason=\(reason)")
#endif
        terminalSurface.forceRefresh(reason: "focus.surface.\(reason)")
    }

    private func applyFirstResponderIfNeeded() {
        let hasUsablePortalGeometry: Bool = {
            let size = bounds.size
            return size.width > 1 && size.height > 1
        }()
        let isHiddenForFocus = isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor
        let surfaceShort = String(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")

        guard isActive else { return }
        guard surfaceView.isVisibleInUI else { return }
        guard !isHiddenForFocus, hasUsablePortalGeometry else {
#if DEBUG
            cmuxDebugLog(
                "focus.apply.skip surface=\(surfaceShort) " +
                "reason=hidden_or_tiny hidden=\(isHiddenForFocus ? 1 : 0) frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height))"
            )
#endif
            return
        }
        guard let window = uiWindow, window.isKeyWindow else { return }
        guard let tabId = surfaceView.tabId,
              let panelId = surfaceView.terminalSurface?.id,
              matchesCurrentTerminalFocusTarget(tabId: tabId, surfaceId: panelId) else {
#if DEBUG
            cmuxDebugLog("focus.apply.skip surface=\(surfaceShort) reason=stale_target")
#endif
            return
        }
        if AppDelegate.shared?.allowsTerminalKeyboardFocus(workspaceId: tabId, panelId: panelId, in: window) == false {
#if DEBUG
            dlog("find.applyFirstResponder SKIP surface=\(surfaceShort) reason=coordinatorRightSidebar")
#endif
            return
        }
        if AppDelegate.shared?.isCommandPaletteEffectivelyVisible(for: window) == true {
#if DEBUG
            cmuxDebugLog("find.applyFirstResponder SKIP surface=\(surfaceShort) reason=commandPaletteVisible")
#endif
            return
        }
        if surfaceView.terminalSurface?.searchState != nil {
            // Find bar is open. Restore focus based on what the user last intended.
            restoreSearchFocus(window: window)
            return
        }
        if let fr = window.firstResponder as? NSView,
           fr === surfaceView || fr.isDescendant(of: surfaceView) {
            reassertTerminalSurfaceFocus(reason: "applyFirstResponder.alreadyFirstResponder")
            return
        }
        // Don't steal focus from a search overlay on another surface in this window.
        if let fr = window.firstResponder, isSearchOverlayOrDescendant(fr) {
#if DEBUG
            cmuxDebugLog("find.applyFirstResponder SKIP surface=\(surfaceShort) reason=searchOverlayFocused")
#endif
            return
        }
        // Don't steal focus from active non-terminal input owners. The terminal surface uses its
        // own GhosttyNSView for input, so NSText and the feed focus host are always foreign focus
        // owners that should survive deferred terminal visibility applies.
        if let firstResponder = window.firstResponder,
           shouldRespectForeignFirstResponder(firstResponder, in: window, isRightSidebarOwner: {
               AppDelegate.shared?.isRightSidebarFocusResponder($0, in: window) == true
           }) {
#if DEBUG
            let reason = firstResponder is NSText ? "textEditorFocused" : "rightSidebarFocused"
            cmuxDebugLog("find.applyFirstResponder SKIP surface=\(surfaceShort) reason=\(reason)")
#endif
            return
        }
#if DEBUG
        cmuxDebugLog("find.applyFirstResponder APPLY surface=\(surfaceShort) prevFirstResponder=\(String(describing: window.firstResponder))")
#endif
        window.makeFirstResponder(surfaceView)
        if isSurfaceViewFirstResponder() {
            reassertTerminalSurfaceFocus(reason: "applyFirstResponder.afterMakeFirstResponder")
        }
    }

    func capturePanelFocusIntent(in window: NSWindow?) -> TerminalPanelFocusIntent {
        if surfaceView.terminalSurface?.searchState != nil {
            if let firstResponder = window?.firstResponder as? NSView,
               (firstResponder === surfaceView || firstResponder.isDescendant(of: surfaceView)) {
                return .surface
            }
            if let firstResponder = window?.firstResponder,
               isCurrentSurfaceSearchResponder(firstResponder) {
                return .findField
            }
            if searchFocusTarget == .searchField {
                return .findField
            }
        }
        return .surface
    }

    func preferredPanelFocusIntentForActivation() -> TerminalPanelFocusIntent {
        if surfaceView.terminalSurface?.searchState != nil, searchFocusTarget == .searchField {
            return .findField
        }
        return .surface
    }

    func responderMatchesPreferredKeyboardFocus(_ responder: NSResponder) -> Bool {
        switch preferredPanelFocusIntentForActivation() {
        case .surface:
            guard let view = resolvedKeyboardFocusOwnerView(for: responder) else { return false }
            return view === surfaceView || view.isDescendant(of: surfaceView)

        case .findField:
            return isCurrentSurfaceSearchResponder(responder) &&
                isSearchOverlayOrDescendant(responder)
        case .textBoxInput:
            return false
        }
    }

    func preparePanelFocusIntentForActivation(_ intent: TerminalPanelFocusIntent) {
        switch intent {
        case .surface:
            searchFocusTarget = .terminal
        case .findField:
            guard surfaceView.terminalSurface?.searchState != nil else { return }
            searchFocusTarget = .searchField
        case .textBoxInput:
            searchFocusTarget = .terminal
        }
#if DEBUG
        let targetLabel: String = {
            switch intent {
            case .surface:
                return "terminal"
            case .findField:
                return "searchField"
            case .textBoxInput:
                return "textBoxInput"
            }
        }()
        cmuxDebugLog(
            "find.preparePanelFocusIntent surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "target=\(targetLabel)"
        )
#endif
    }

    @discardableResult
    func restorePanelFocusIntent(_ intent: TerminalPanelFocusIntent) -> Bool {
        switch intent {
        case .surface:
            searchFocusTarget = .terminal
            setActive(true)
            applyFirstResponderIfNeeded()
            return true
        case .findField:
            guard let terminalSurface = surfaceView.terminalSurface,
                  terminalSurface.searchState != nil else {
                return false
            }
            searchFocusTarget = .searchField
            setActive(true)
            if let window {
                restoreSearchFocus(window: window)
            } else {
                terminalSurface.setFocus(false)
                NotificationCenter.default.post(name: .ghosttySearchFocus, object: terminalSurface)
            }
#if DEBUG
            cmuxDebugLog(
                "find.restorePanelFocusIntent surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "target=searchField firstResponder=\(String(describing: window?.firstResponder))"
            )
#endif
            return true
        case .textBoxInput:
            return false
        }
    }

    func ownedPanelFocusIntent(for responder: NSResponder) -> TerminalPanelFocusIntent? {
        if isCurrentSurfaceSearchResponder(responder) {
            return .findField
        }

        guard let view = resolvedKeyboardFocusOwnerView(for: responder) else { return nil }
        if view === surfaceView || view.isDescendant(of: surfaceView) {
            return .surface
        }
        return nil
    }

    @discardableResult
    func yieldPanelFocusIntent(_ intent: TerminalPanelFocusIntent, in window: NSWindow) -> Bool {
        guard intent != .textBoxInput else {
            return false
        }
        guard let firstResponder = window.firstResponder,
              ownedPanelFocusIntent(for: firstResponder) == intent else {
            return false
        }
        if intent == .findField { _ = cmuxRememberFindSelection(in: searchOverlayHostingView) }
        surfaceView.terminalSurface?.setFocus(false)
        resignOwnedFirstResponderIfNeeded(reason: "yieldPanelFocusIntent")
#if DEBUG
        cmuxDebugLog(
            "focus.handoff.yield surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "target=\(intent == .findField ? "searchField" : "terminal")"
        )
#endif
        return true
    }

    func resignOwnedFirstResponderIfNeeded(reason: String) {
        guard let window,
              let firstResponder = window.firstResponder else { return }

        let ownsSurfaceResponder: Bool = {
            guard let view = firstResponder as? NSView else { return false }
            return view === surfaceView || view.isDescendant(of: surfaceView)
        }()

        guard ownsSurfaceResponder || isCurrentSurfaceSearchResponder(firstResponder) else { return }

#if DEBUG
        cmuxDebugLog(
            "focus.surface.resign surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "reason=\(reason) firstResponder=\(String(describing: firstResponder))"
        )
#endif
        window.makeFirstResponder(nil)
    }

    /// Check if a responder is inside a search overlay hosting view.
    /// Handles the AppKit field-editor case: when an NSTextField is being edited,
    /// window.firstResponder is the shared NSTextView field editor, not the text field.
    func isSearchOverlayOrDescendant(_ responder: NSResponder) -> Bool {
        guard let view = resolvedKeyboardFocusOwnerView(for: responder) else { return false }
        var current: NSView? = view
        while let v = current {
            if v is NSHostingView<SurfaceSearchOverlay> { return true }
            let typeName = String(describing: type(of: v))
            if typeName.contains("BrowserSearchOverlay") { return true }
            current = v.superview
        }
        return false
    }

    func isCurrentSurfaceSearchResponder(_ responder: NSResponder) -> Bool {
        guard let view = resolvedKeyboardFocusOwnerView(for: responder) else { return false }
        return view.isDescendant(of: self)
    }

    func isCurrentSurfaceSearchFieldResponder(_ responder: NSResponder) -> Bool {
        if let mountedSearchField = mountedSearchFieldIfAvailable(),
           mountedSearchFieldOwnsResponder(responder, field: mountedSearchField) {
            return mountedSearchField.isDescendant(of: self) &&
                isSearchOverlayOrDescendant(mountedSearchField)
        }

        guard let textField = responder as? NSTextField else { return false }
        return textField.isDescendant(of: self) && isSearchOverlayOrDescendant(textField)
    }

    func cancelFocusRequest() {
        // Intentionally no-op (no retry loops).
    }

}
