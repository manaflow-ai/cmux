import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Tab selection and activation
extension Workspace {
    @MainActor
    func shouldCloseWorkspaceOnLastSurface(for tabId: TabID) -> Bool {
        let manager = owningTabManager ?? AppDelegate.shared?.tabManagerFor(tabId: id) ?? AppDelegate.shared?.tabManager
        guard panels.count <= 1,
              panelIdFromSurfaceId(tabId) != nil,
              let manager,
              manager.tabs.contains(where: { $0.id == id }) else {
            return false
        }
        return true
    }

    @MainActor
    func confirmClosePanel(for tabId: TabID) async -> Bool {
        let title = String(localized: "dialog.closeTab.title", defaultValue: "Close tab?")
        let panelName: String? = {
            guard let panelId = panelIdFromSurfaceId(tabId) else { return nil }
            if let custom = panelCustomTitles[panelId], !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return custom
            }
            if let title = panelTitles[panelId], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title
            }
            if let dir = panelDirectories[panelId], !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (dir as NSString).lastPathComponent
            }
            return nil
        }()

        let message: String
        if let panelName {
            message = String(localized: "dialog.closeTab.messageNamed", defaultValue: "This will close \"\(panelName)\".")
        } else {
            message = String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab.")
        }

        if let confirmCloseHandler = (
            owningTabManager
            ?? AppDelegate.shared?.tabManagerFor(tabId: id)
            ?? AppDelegate.shared?.tabManager
        )?.confirmCloseHandler {
            return confirmCloseHandler(title, message, false)
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))

        if let closeButton = alert.buttons.first {
            closeButton.keyEquivalent = "\r"
            closeButton.keyEquivalentModifierMask = []
            alert.window.defaultButtonCell = closeButton.cell as? NSButtonCell
            alert.window.initialFirstResponder = closeButton
        }
        if let cancelButton = alert.buttons.dropFirst().first {
            cancelButton.keyEquivalent = "\u{1b}"
        }

        // Prefer a sheet if we can find a window, otherwise fall back to modal.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Apply the side-effects of selecting a tab (unfocus others, focus this panel, update state).
    /// bonsplit doesn't always emit didSelectTab for programmatic selection paths (e.g. createTab).
    func applyTabSelection(
        tabId: TabID,
        inPane pane: PaneID,
        reassertAppKitFocus: Bool = true,
        focusIntent: PanelFocusIntent? = nil,
        resumeHibernatedAgent: Bool? = nil,
        previousTerminalHostedView: GhosttySurfaceScrollView? = nil
    ) {
        pendingTabSelection = PendingTabSelectionRequest(
            tabId: tabId,
            pane: pane,
            reassertAppKitFocus: reassertAppKitFocus,
            focusIntent: focusIntent,
            resumeHibernatedAgent: resumeHibernatedAgent,
            previousTerminalHostedView: previousTerminalHostedView
        )
        guard !isApplyingTabSelection else { return }
        isApplyingTabSelection = true
        defer {
            isApplyingTabSelection = false
            pendingTabSelection = nil
        }

        var iterations = 0
        while let request = pendingTabSelection {
            pendingTabSelection = nil
            iterations += 1
            if iterations > 8 { break }
            applyTabSelectionNow(
                tabId: request.tabId,
                inPane: request.pane,
                reassertAppKitFocus: request.reassertAppKitFocus,
                focusIntent: request.focusIntent,
                resumeHibernatedAgent: request.resumeHibernatedAgent,
                previousTerminalHostedView: request.previousTerminalHostedView
            )
        }
    }

    /// Hide browser portals for tabs that are no longer selected in the given pane.
    func hideBrowserPortalsForDeselectedTabs(inPane pane: PaneID, selectedTabId: TabID) {
        for tab in bonsplitController.tabs(inPane: pane) {
            guard tab.id != selectedTabId else { continue }
            guard let panelId = panelIdFromSurfaceId(tab.id),
                  let browserPanel = panels[panelId] as? BrowserPanel else { continue }
            browserPanel.hideBrowserPortalView(source: "tabDeselected")
        }
    }

    private func applyTabSelectionNow(
        tabId: TabID,
        inPane pane: PaneID,
        reassertAppKitFocus: Bool,
        focusIntent: PanelFocusIntent?,
        resumeHibernatedAgent: Bool?,
        previousTerminalHostedView: GhosttySurfaceScrollView?
    ) {
        let previousFocusedPanelId = focusedPanelId
#if DEBUG
        let focusedPaneBefore = bonsplitController.focusedPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let selectedTabBefore = bonsplitController.focusedPaneId
            .flatMap { bonsplitController.selectedTab(inPane: $0)?.id }
            .map { String($0.uuid.uuidString.prefix(5)) } ?? "nil"
        cmuxDebugLog(
            "focus.split.apply.begin workspace=\(id.uuidString.prefix(5)) " +
            "pane=\(pane.id.uuidString.prefix(5)) tab=\(tabId.uuid.uuidString.prefix(5)) " +
            "focusedPane=\(focusedPaneBefore) selectedTab=\(selectedTabBefore) " +
            "reassert=\(reassertAppKitFocus ? 1 : 0)"
        )
#endif
        if bonsplitController.allPaneIds.contains(pane) {
            if bonsplitController.focusedPaneId != pane {
                bonsplitController.focusPane(pane)
            }
            if bonsplitController.tabs(inPane: pane).contains(where: { $0.id == tabId }),
               bonsplitController.selectedTab(inPane: pane)?.id != tabId {
                bonsplitController.selectTab(tabId)
            }
        }

        let focusedPane: PaneID
        let selectedTabId: TabID
        if let currentPane = bonsplitController.focusedPaneId,
           let currentTabId = bonsplitController.selectedTab(inPane: currentPane)?.id {
            focusedPane = currentPane
            selectedTabId = currentTabId
        } else if bonsplitController.tabs(inPane: pane).contains(where: { $0.id == tabId }) {
            focusedPane = pane
            selectedTabId = tabId
            bonsplitController.focusPane(focusedPane)
            bonsplitController.selectTab(selectedTabId)
        } else {
            return
        }

        // Focus the selected panel, but keep the previously focused terminal active while a
        // newly created split terminal is still unattached.
        guard let selectedPanelId = panelIdFromSurfaceId(selectedTabId) else {
            return
        }
        let effectiveFocusedPanelId = effectiveSelectedPanelId(inPane: focusedPane) ?? selectedPanelId
        guard let panel = panels[effectiveFocusedPanelId] else {
            return
        }

        if debugStressPreloadSelectionDepth > 0 {
            if let terminalPanel = panel as? TerminalPanel {
                terminalPanel.requestViewReattach()
                scheduleTerminalGeometryReconcile()
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
            }
            return
        }

        let explicitFocusIntent = shouldTreatCurrentEventAsExplicitFocusIntent()
        if explicitFocusIntent {
            markExplicitFocusIntent(on: effectiveFocusedPanelId)
        }
        // Selecting a hibernated tab means the user is visiting it again. Resume by
        // default so sidebar/tab selection behaves the same as pressing Resume.
        let shouldResumeHibernatedAgent = resumeHibernatedAgent ?? true
        let activationIntent = focusIntent ?? panel.preferredFocusIntentForActivation()
        panel.prepareFocusIntentForActivation(activationIntent)
        let panelId = effectiveFocusedPanelId
        if let terminalPanel = panel as? TerminalPanel {
            if terminalPanel.isAgentHibernated, shouldResumeHibernatedAgent {
                _ = resumeAgentHibernation(panelId: panelId, focus: false)
            }
            AgentHibernationController.shared.recordTerminalFocus(workspaceId: id, panelId: panelId)
        }

        syncPinnedStateForTab(selectedTabId, panelId: selectedPanelId)
        if previousFocusedPanelId != panelId {
            syncUnreadBadgeStateForAllPanels()
        } else {
            syncUnreadBadgeStateForPanel(selectedPanelId)
        }

        // Unfocus all other panels
        for (id, p) in panels where id != effectiveFocusedPanelId {
            p.unfocus()
        }

        // Explicitly hide browser portals for deselected tabs in this pane.
        // Bonsplit's keepAllAlive mode hides non-selected tabs via SwiftUI .opacity(0),
        // but portal-hosted WKWebViews render at the window level in AppKit and are not
        // affected by SwiftUI opacity. Without an explicit hide, the deselected browser's
        // portal layer can remain visible above the newly selected tab.
        hideBrowserPortalsForDeselectedTabs(inPane: focusedPane, selectedTabId: selectedTabId)

        if let focusWindow = activationWindow(for: panel) {
            yieldForeignOwnedFocusIfNeeded(
                in: focusWindow,
                targetPanelId: panelId,
                targetIntent: activationIntent
            )
        }

        activatePanel(
            panel,
            focusIntent: activationIntent,
            reassertAppKitFocus: reassertAppKitFocus
        )
        let focusIntentAllowsBrowserOmnibarAutofocus =
            explicitFocusIntent ||
            TerminalController.socketCommandAllowsInAppFocusMutations()
        if let browserPanel = panel as? BrowserPanel,
           shouldAllowBrowserOmnibarAutofocus(for: activationIntent),
           previousFocusedPanelId != panelId || focusIntentAllowsBrowserOmnibarAutofocus {
            maybeAutoFocusBrowserAddressBarOnPanelFocus(browserPanel, trigger: .standard)
        }
        if let terminalPanel = panel as? TerminalPanel {
            rememberTerminalConfigInheritanceSource(terminalPanel)
        }

        // Converge AppKit first responder with bonsplit's selected tab in the focused pane.
        // Without this, keyboard input can remain on a different terminal than the blue tab indicator.
        if reassertAppKitFocus, let terminalPanel = panel as? TerminalPanel {
            if shouldMoveTerminalSurfaceFocus(for: activationIntent) {
                if !terminalPanel.hostedView.isSurfaceViewFirstResponder() {
#if DEBUG
                    let previousExists = previousTerminalHostedView != nil ? 1 : 0
                    cmuxDebugLog(
                        "focus.split.moveFocus workspace=\(id.uuidString.prefix(5)) " +
                        "panel=\(panelId.uuidString.prefix(5)) previousExists=\(previousExists) " +
                        "to=\(panelId.uuidString.prefix(5))"
                    )
#endif
                    terminalPanel.hostedView.moveFocus(from: previousTerminalHostedView)
                }
#if DEBUG
                cmuxDebugLog(
                    "focus.split.ensureFocus workspace=\(id.uuidString.prefix(5)) " +
                    "panel=\(panelId.uuidString.prefix(5)) pane=\(focusedPane.id.uuidString.prefix(5)) " +
                    "tab=\(selectedTabId.uuid.uuidString.prefix(5)) intent=\(String(describing: activationIntent))"
                )
#endif
                terminalPanel.hostedView.ensureFocus(for: id, surfaceId: panelId)
            }
        }

        if shouldRestoreFocusIntentAfterActivation(activationIntent) {
            _ = panel.restoreFocusIntent(activationIntent)
        }

        surfaceTabBarDirectory = configTrackingDirectory(for: panelId)

        // Update current directory if this is a terminal
        if let dir = panelDirectories[panelId] {
            currentDirectory = dir
        }
        gitBranch = panelGitBranches[panelId]
        pullRequest = panelPullRequests[panelId]

        // Broadcast the focus change. This is deferred + coalesced (not posted
        // synchronously) so the `@Published` mutations above settle before any
        // observer runs, and so a notification-driven focus cycle (command-palette
        // restore + cross-workspace handoff) cannot synchronously re-enter
        // applyTabSelectionNow and hang the main thread. See issue #5100.
        FocusSurfaceBroadcaster.shared.emit(
            FocusSurfaceBroadcaster.FocusSurfacePayload(
                workspaceId: self.id,
                panelId: panelId,
                explicitFocusIntent: explicitFocusIntent
            )
        )
        publishCmuxFocusedSelection(paneId: focusedPane, surfaceId: panelId, origin: "bonsplit_selection")
#if DEBUG
        let prevPanelShort = previousFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        cmuxDebugLog(
            "focus.split.apply.end workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) type=\(String(describing: type(of: panel))) " +
            "focusedPane=\(focusedPane.id.uuidString.prefix(5)) selectedTab=\(selectedTabId.uuid.uuidString.prefix(5)) " +
            "prevPanel=\(prevPanelShort)"
        )
#endif
    }

    private func activatePanel(
        _ panel: any Panel,
        focusIntent: PanelFocusIntent,
        reassertAppKitFocus: Bool
    ) {
        if let terminalPanel = panel as? TerminalPanel {
            let shouldFocusTerminalSurface = shouldMoveTerminalSurfaceFocus(for: focusIntent)
            terminalPanel.surface.setFocus(shouldFocusTerminalSurface)
            terminalPanel.hostedView.setActive(true)
            if reassertAppKitFocus && shouldFocusTerminalSurface {
                terminalPanel.focus()
            }
            return
        }

        if let browserPanel = panel as? BrowserPanel {
            guard shouldFocusBrowserWebView(for: focusIntent) else { return }
            browserPanel.focus()
            return
        }

        if reassertAppKitFocus {
            panel.focus()
        }
    }

    private func activationWindow(for panel: any Panel) -> NSWindow? {
        if let terminalPanel = panel as? TerminalPanel {
            return terminalPanel.surface.uiWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        }
        if let browserPanel = panel as? BrowserPanel {
            return browserPanel.webView.window ?? browserPanel.portalAnchorView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        }
        return NSApp.keyWindow ?? NSApp.mainWindow
    }

    private func yieldForeignOwnedFocusIfNeeded(
        in window: NSWindow,
        targetPanelId: UUID,
        targetIntent: PanelFocusIntent
    ) {
        guard let firstResponder = window.firstResponder else { return }

        for (panelId, panel) in panels where panelId != targetPanelId {
            guard let ownedIntent = panel.ownedFocusIntent(for: firstResponder, in: window) else { continue }
#if DEBUG
            cmuxDebugLog(
                "focus.handoff.begin workspace=\(id.uuidString.prefix(5)) " +
                "fromPanel=\(panelId.uuidString.prefix(5)) toPanel=\(targetPanelId.uuidString.prefix(5)) " +
                "fromIntent=\(String(describing: ownedIntent)) toIntent=\(String(describing: targetIntent))"
            )
#endif
            _ = panel.yieldFocusIntent(ownedIntent, in: window)
            return
        }
    }

    private func shouldMoveTerminalSurfaceFocus(for intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .terminal(.findField), .terminal(.textBoxInput):
            return false
        default:
            return true
        }
    }

    private func shouldFocusBrowserWebView(for intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .browser(.addressBar), .browser(.findField):
            return false
        default:
            return true
        }
    }

    private func shouldAllowBrowserOmnibarAutofocus(for intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .browser(.webView), .panel:
            return true
        default:
            return false
        }
    }

    private func shouldRestoreFocusIntentAfterActivation(_ intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .browser(.addressBar), .browser(.findField), .terminal(.findField), .terminal(.textBoxInput):
            return true
        case .panel, .browser(.webView), .terminal(.surface), .filePreview, .project:
            return false
        }
    }

    func beginNonFocusSplitFocusReassert(
        preferredPanelId: UUID,
        splitPanelId: UUID
    ) -> UInt64 {
        nonFocusSplitFocusReassertGeneration &+= 1
        let generation = nonFocusSplitFocusReassertGeneration
        pendingNonFocusSplitFocusReassert = PendingNonFocusSplitFocusReassert(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )
        return generation
    }

    func matchesPendingNonFocusSplitFocusReassert(
        generation: UInt64,
        preferredPanelId: UUID,
        splitPanelId: UUID
    ) -> Bool {
        guard let pending = pendingNonFocusSplitFocusReassert else { return false }
        return pending.generation == generation &&
            pending.preferredPanelId == preferredPanelId &&
            pending.splitPanelId == splitPanelId
    }

    func clearNonFocusSplitFocusReassert(generation: UInt64? = nil) {
        guard let pending = pendingNonFocusSplitFocusReassert else { return }
        if let generation, pending.generation != generation { return }
        pendingNonFocusSplitFocusReassert = nil
    }

    private func shouldTreatCurrentEventAsExplicitFocusIntent() -> Bool {
        guard let eventType = NSApp.currentEvent?.type else { return false }
        switch eventType {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .keyDown, .keyUp, .scrollWheel,
             .gesture, .magnify, .rotate, .swipe:
            return true
        default:
            return false
        }
    }

    func markExplicitFocusIntent(on panelId: UUID) {
        guard let pending = pendingNonFocusSplitFocusReassert,
              pending.splitPanelId == panelId else {
            return
        }
        pendingNonFocusSplitFocusReassert = nil
    }

}
