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


// MARK: - Browser address bar focus and omnibar selection
extension AppDelegate {
#if DEBUG
    private func logBrowserZoomShortcutTrace(
        stage: String,
        event: NSEvent,
        flags: NSEvent.ModifierFlags,
        chars: String,
        action: BrowserZoomShortcutAction? = nil,
        handled: Bool? = nil
    ) {
        guard browserZoomShortcutTraceCandidate(
            flags: flags,
            chars: chars,
            keyCode: event.keyCode,
            literalChars: event.characters
        ) else {
            return
        }

        let keyWindow = NSApp.keyWindow
        let firstResponderType = keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let panel = tabManager?.focusedBrowserPanel
        let panelToken = panel.map { String($0.id.uuidString.prefix(8)) } ?? "nil"
        let panelZoom = panel?.webView.pageZoom ?? -1
        var line =
            "zoom.shortcut stage=\(stage) event=\(NSWindow.keyDescription(event)) " +
            "chars='\(chars)' flags=\(browserZoomShortcutTraceFlagsString(flags)) " +
            "action=\(browserZoomShortcutTraceActionString(action)) keyWin=\(keyWindow?.windowNumber ?? -1) " +
            "fr=\(firstResponderType) panel=\(panelToken) zoom=\(String(format: "%.3f", panelZoom)) " +
            "addrBarId=\(browserAddressBarFocusedPanelId?.uuidString.prefix(8) ?? "nil")"
        if let handled {
            line += " handled=\(handled ? 1 : 0)"
        }
        cmuxDebugLog(line)
    }

    private func browserFocusStateSnapshot() -> String {
        let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let focused = tabManager?.selectedWorkspace?.focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let addressBar = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let keyWindow = NSApp.keyWindow?.windowNumber ?? -1
        let firstResponderType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "selected=\(selected) focused=\(focused) addr=\(addressBar) keyWin=\(keyWindow) fr=\(firstResponderType)"
    }

    private func redactedDebugURL(_ url: URL?) -> String {
        guard let url else { return "nil" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<invalid>"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "<redacted>"
    }
#endif

    @discardableResult
    func focusBrowserAddressBar(panelId: UUID) -> Bool {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panel = workspace.browserPanel(for: panelId) else {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.route panel=\(panelId.uuidString.prefix(5)) " +
                "result=miss \(browserFocusStateSnapshot())"
            )
#endif
            return false
        }
#if DEBUG
        cmuxDebugLog(
            "browser.focus.addressBar.route panel=\(panel.id.uuidString.prefix(5)) " +
            "workspace=\(workspace.id.uuidString.prefix(5)) result=hit \(browserFocusStateSnapshot())"
        )
#endif
        workspace.focusPanel(panel.id)
#if DEBUG
        let focusedAfter = workspace.focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        cmuxDebugLog(
            "browser.focus.addressBar.route panel=\(panel.id.uuidString.prefix(5)) " +
            "workspace=\(workspace.id.uuidString.prefix(5)) focusedAfter=\(focusedAfter)"
        )
#endif
        focusBrowserAddressBar(in: panel)
        return true
    }

    @discardableResult
    func openBrowserAndFocusAddressBar(url: URL? = nil, insertAtEnd: Bool = false) -> UUID? {
        guard BrowserAvailabilitySettings.isEnabled() else {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.openAndFocus result=blocked_browser_disabled " +
                "insertAtEnd=\(insertAtEnd ? 1 : 0) url=\(redactedDebugURL(url))"
            )
#endif
            return nil
        }

        let preferredProfileID =
            tabManager?.focusedBrowserPanel?.profileID
            ?? tabManager?.selectedWorkspace?.preferredBrowserProfileID
        guard let panelId = tabManager?.openBrowser(
            url: url,
            preferredProfileID: preferredProfileID,
            insertAtEnd: insertAtEnd
        ) else {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.openAndFocus result=open_failed insertAtEnd=\(insertAtEnd ? 1 : 0) " +
                "url=\(redactedDebugURL(url)) \(browserFocusStateSnapshot())"
            )
#endif
            return nil
        }
#if DEBUG
        cmuxDebugLog(
            "browser.focus.openAndFocus result=open_ok panel=\(panelId.uuidString.prefix(5)) " +
            "insertAtEnd=\(insertAtEnd ? 1 : 0) url=\(redactedDebugURL(url))"
        )
#endif
#if DEBUG
        let didFocus = focusBrowserAddressBar(panelId: panelId)
        cmuxDebugLog(
            "browser.focus.openAndFocus result=focus_request panel=\(panelId.uuidString.prefix(5)) " +
            "focused=\(didFocus ? 1 : 0) \(browserFocusStateSnapshot())"
        )
#else
        _ = focusBrowserAddressBar(panelId: panelId)
#endif
        return panelId
    }

    @discardableResult
    func openSidebarExtensionBrowser(from anchorView: NSView?, title: String) -> UUID? {
        // Defensive gate: the extensions browser is part of the experimental
        // Extensions feature. Its entry points are hidden while disabled, but
        // guard here too so no other path can open it.
        guard CmuxExtensionSidebarSelection.isEnabled else { return nil }
        let preferredWindow = anchorView?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        let targetTabManager = synchronizeActiveMainWindowContext(preferredWindow: preferredWindow)
        guard let workspace = targetTabManager?.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return nil
        }

        return workspace.newSidebarExtensionBrowserSurface(
            inPane: paneId,
            title: title,
            focus: true
        )?.id
    }

    func focusBrowserAddressBar(in panel: BrowserPanel) {
#if DEBUG
        let requestId = panel.requestAddressBarFocus(selectionIntent: .selectAll)
        cmuxDebugLog(
            "browser.focus.addressBar.request panel=\(panel.id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8)) \(browserFocusStateSnapshot())"
        )
#else
        _ = panel.requestAddressBarFocus(selectionIntent: .selectAll)
#endif
        browserAddressBarFocusedPanelId = panel.id
#if DEBUG
        cmuxDebugLog(
            "browser.focus.addressBar.sticky panel=\(panel.id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8)) \(browserFocusStateSnapshot())"
        )
#endif
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: panel.id)
#if DEBUG
        cmuxDebugLog(
            "browser.focus.addressBar.notify panel=\(panel.id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8))"
        )
#endif
    }

    func focusedBrowserAddressBarPanelId() -> UUID? {
        browserAddressBarFocusedPanelId
    }

    func focusedBrowserOmnibarField(for event: NSEvent, in window: NSWindow?) -> OmnibarNativeTextField? {
        let panelId = focusedBrowserAddressBarPanelIdForShortcutEvent(event)
        return browserOmnibarField(panelId: panelId, in: window)
    }

    func clearBrowserAddressBarFocus(panelId: UUID, reason: String) {
        guard browserAddressBarFocusedPanelId == panelId else { return }
        browserAddressBarFocusedPanelId = nil
        stopBrowserOmnibarSelectionRepeat()
#if DEBUG
        cmuxDebugLog("addressBar CLEAR panelId=\(panelId.uuidString.prefix(8)) reason=\(reason)")
#endif
    }

    func focusedBrowserAddressBarPanelIdForShortcutEvent(_ event: NSEvent) -> UUID? {
        let shortcutWindow = resolvedShortcutEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow
        let shortcutResponder = shortcutWindow?.firstResponder
        let responderPanelId = isBrowserOmnibarResponder(shortcutResponder)
            ? browserOmnibarPanelId(for: shortcutResponder)
            : nil

        guard let context = preferredMainWindowContextForShortcutRouting(event: event) else {
#if DEBUG
            let candidatePanelId = responderPanelId ?? browserAddressBarFocusedPanelId
            guard let candidatePanelId else { return nil }
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(candidatePanelId.uuidString.prefix(5)) " +
                "accepted=0 reason=no_context event=\(NSWindow.keyDescription(event))"
            )
#endif
            return nil
        }

        let intentPanelId = browserAddressBarIntentPanelId(in: context, window: shortcutWindow)
        guard let panelId = responderPanelId ?? browserAddressBarFocusedPanelId ?? intentPanelId else { return nil }

        guard let workspace = context.tabManager.selectedWorkspace else {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=0 reason=no_workspace event=\(NSWindow.keyDescription(event))"
            )
#endif
            return nil
        }

        guard let panel = workspace.browserPanel(for: panelId) else {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=0 reason=panel_not_in_workspace workspace=\(workspace.id.uuidString.prefix(5)) " +
                "event=\(NSWindow.keyDescription(event))"
            )
#endif
            return nil
        }

        if let responderPanelId {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(responderPanelId.uuidString.prefix(5)) " +
                "accepted=1 reason=omnibar_responder workspace=\(workspace.id.uuidString.prefix(5)) " +
                "event=\(NSWindow.keyDescription(event))"
            )
#endif
            return responderPanelId
        }

        if intentPanelId == panelId, browserAddressBarFocusedPanelId == nil {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=1 reason=addressbar_intent workspace=\(workspace.id.uuidString.prefix(5)) " +
                "event=\(NSWindow.keyDescription(event))"
            )
#endif
            return panelId
        }

        let liveOmnibarFieldExists = browserOmnibarField(panelId: panelId, in: shortcutWindow) != nil
        let trackedPanelMatchesShortcutResponder = browserPanel(panel, ownsShortcutResponder: shortcutResponder, in: shortcutWindow)
        let trackingContext = BrowserAddressBarTrackingContext(
            trackedPanelMatchesWebView: trackedPanelMatchesShortcutResponder,
            omnibarResponderActive: false,
            preferredFocusIntentIsAddressBar: panel.preferredFocusIntent == .addressBar,
            suppressesWebViewFocus: panel.shouldSuppressWebViewFocus(),
            pointerInitiatedWebFocus: false,
            liveOmnibarFieldExists: liveOmnibarFieldExists
        )
        if shouldPreserveBrowserAddressBarTrackingDuringWebViewFocus(trackingContext) {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=1 reason=tracked_omnibar_field workspace=\(workspace.id.uuidString.prefix(5)) " +
                "event=\(NSWindow.keyDescription(event))"
            )
#endif
            return panelId
        }

        if shouldPreserveBrowserAddressBarTrackingDuringTransientShortcutResponder(
            for: panel,
            responder: shortcutResponder,
            in: shortcutWindow,
            liveOmnibarFieldExists: liveOmnibarFieldExists
        ) {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=1 reason=transient_omnibar_focus workspace=\(workspace.id.uuidString.prefix(5)) " +
                "event=\(NSWindow.keyDescription(event))"
            )
#endif
            return panelId
        }

#if DEBUG
        let focusedPanel = workspace.focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        cmuxDebugLog(
            "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
            "accepted=0 reason=responder_not_omnibar responder=\(shortcutResponder.map { String(describing: type(of: $0)) } ?? "nil") " +
            "pending=\(panel.pendingAddressBarFocusRequestId != nil ? 1 : 0) focusedPanel=\(focusedPanel) " +
            "event=\(NSWindow.keyDescription(event))"
        )
#endif
        return nil
    }

    private func shouldPreserveBrowserAddressBarTrackingDuringTransientShortcutResponder(
        for panel: BrowserPanel,
        responder: NSResponder?,
        in window: NSWindow?,
        liveOmnibarFieldExists: Bool
    ) -> Bool {
        guard browserAddressBarFocusedPanelId == panel.id else { return false }
        guard panel.preferredFocusIntent == .addressBar else { return false }
        guard panel.shouldSuppressWebViewFocus() ||
            liveOmnibarFieldExists ||
            panel.pendingAddressBarFocusRequestId != nil else {
            return false
        }

        guard let responder else { return true }
        if let window, responder === window {
            return true
        }
        if responder is NSWindow {
            return true
        }
        if browserOmnibarPanelId(for: responder) == panel.id {
            return true
        }
        if cmuxOwningGhosttyView(for: responder) != nil {
            return false
        }
        if responder is NSTextView || responder is NSTextField {
            return false
        }
        if let window, panel.ownedFocusIntent(for: responder, in: window) != nil {
            return false
        }
        return false
    }

    private func browserAddressBarIntentPanelId(
        in context: MainWindowContext,
        window: NSWindow?
    ) -> UUID? {
        guard let workspace = context.tabManager.selectedWorkspace,
              let focusedPanelId = workspace.focusedPanelId,
              let panel = workspace.browserPanel(for: focusedPanelId),
              panel.preferredFocusIntent == .addressBar,
              let field = browserOmnibarField(panelId: panel.id, in: window) else {
            return nil
        }

        guard panel.shouldSuppressWebViewFocus() || field.currentEditor() != nil else {
            return nil
        }
        return panel.id
    }

    func browserPanel(
        _ panel: BrowserPanel,
        ownsShortcutResponder responder: NSResponder?,
        in window: NSWindow?
    ) -> Bool {
        guard let responder, let window else { return false }
        if browserOmnibarPanelId(for: responder) == panel.id {
            return true
        }
        if case .browser(.webView)? = panel.ownedFocusIntent(for: responder, in: window) {
            return true
        }
        return false
    }

    private func browserOmnibarOwnerView(for responder: NSResponder?) -> NSView? {
        guard let responder else { return nil }

        if let textView = responder as? NSTextView,
           textView.isFieldEditor,
           let delegateView = textView.delegate as? NSView,
           delegateView.identifier == browserOmnibarTextFieldIdentifier {
            return delegateView
        }

        let ownerView = keyRoutingOwnerView(for: responder)
        guard ownerView?.identifier == browserOmnibarTextFieldIdentifier else { return nil }
        return ownerView
    }

    private func isBrowserOmnibarResponder(_ responder: NSResponder?) -> Bool {
        guard let ownerView = browserOmnibarOwnerView(for: responder) else { return false }

        if let fieldEditor = responder as? NSTextView,
           fieldEditor.isFieldEditor {
            return (ownerView as? NSTextField)?.currentEditor() === fieldEditor
        }

        return true
    }

    func shouldPreserveBrowserAddressBarTracking(
        for panel: BrowserPanel,
        trackedPanelMatchesWebView: Bool,
        pointerInitiatedWebFocus: Bool = false,
        in window: NSWindow? = nil
    ) -> Bool {
        guard browserAddressBarFocusedPanelId == panel.id else { return false }
        let resolvedWindow = window ?? panel.webView.window
        let trackingContext = BrowserAddressBarTrackingContext(
            trackedPanelMatchesWebView: trackedPanelMatchesWebView,
            omnibarResponderActive: isBrowserOmnibarResponder(resolvedWindow?.firstResponder),
            preferredFocusIntentIsAddressBar: panel.preferredFocusIntent == .addressBar,
            suppressesWebViewFocus: panel.shouldSuppressWebViewFocus(),
            pointerInitiatedWebFocus: pointerInitiatedWebFocus,
            liveOmnibarFieldExists: browserOmnibarField(panelId: panel.id, in: resolvedWindow) != nil
        )
        return shouldPreserveBrowserAddressBarTrackingDuringWebViewFocus(trackingContext)
    }

    @discardableResult
    func requestBrowserAddressBarFocus(panelId: UUID) -> Bool {
        focusBrowserAddressBar(panelId: panelId)
    }

    func controlOmnibarSelectionDelta(
        hasFocusedAddressBar: Bool,
        flags: NSEvent.ModifierFlags,
        chars: String
    ) -> Int? {
        browserOmnibarSelectionDeltaForControlNavigation(
            hasFocusedAddressBar: hasFocusedAddressBar,
            flags: flags,
            chars: chars
        )
    }

    func dispatchBrowserOmnibarSelectionMove(panelId: UUID, delta: Int) {
        guard delta != 0 else { return }
#if DEBUG
        cmuxDebugLog(
            "browser.focus.omnibar.selectionMove panel=\(panelId.uuidString.prefix(5)) " +
            "delta=\(delta) repeatKey=\(browserOmnibarRepeatKeyCode.map(String.init) ?? "nil")"
        )
#endif
        NotificationCenter.default.post(
            name: .browserMoveOmnibarSelection,
            object: panelId,
            userInfo: ["delta": delta]
        )
    }

    func startBrowserOmnibarSelectionRepeatIfNeeded(panelId: UUID, keyCode: UInt16, delta: Int) {
        guard delta != 0 else { return }

        if browserOmnibarRepeatPanelId == panelId,
           browserOmnibarRepeatKeyCode == keyCode,
           browserOmnibarRepeatDelta == delta {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.omnibar.repeat.start panel=\(panelId.uuidString.prefix(5)) " +
                "key=\(keyCode) delta=\(delta) result=reuse"
            )
#endif
            return
        }

        stopBrowserOmnibarSelectionRepeat()
        browserOmnibarRepeatPanelId = panelId
        browserOmnibarRepeatKeyCode = keyCode
        browserOmnibarRepeatDelta = delta
#if DEBUG
        cmuxDebugLog(
            "browser.focus.omnibar.repeat.start panel=\(panelId.uuidString.prefix(5)) " +
            "key=\(keyCode) delta=\(delta) result=armed"
        )
#endif

        let start = DispatchWorkItem { [weak self] in
            self?.scheduleBrowserOmnibarSelectionRepeatTick()
        }
        browserOmnibarRepeatStartWorkItem = start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: start)
    }

    private func scheduleBrowserOmnibarSelectionRepeatTick() {
        browserOmnibarRepeatStartWorkItem = nil
        guard let panelId = browserOmnibarRepeatPanelId else {
#if DEBUG
            cmuxDebugLog("browser.focus.omnibar.repeat.tick result=stop_no_focused_address_bar")
#endif
            stopBrowserOmnibarSelectionRepeat()
            return
        }
        guard browserOmnibarRepeatKeyCode != nil else { return }

#if DEBUG
        cmuxDebugLog(
            "browser.focus.omnibar.repeat.tick panel=\(panelId.uuidString.prefix(5)) " +
            "delta=\(browserOmnibarRepeatDelta)"
        )
#endif
        dispatchBrowserOmnibarSelectionMove(panelId: panelId, delta: browserOmnibarRepeatDelta)

        let tick = DispatchWorkItem { [weak self] in
            self?.scheduleBrowserOmnibarSelectionRepeatTick()
        }
        browserOmnibarRepeatTickWorkItem = tick
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055, execute: tick)
    }

    func stopBrowserOmnibarSelectionRepeat() {
#if DEBUG
        let previousPanelId = browserOmnibarRepeatPanelId
        let previousKeyCode = browserOmnibarRepeatKeyCode
        let previousDelta = browserOmnibarRepeatDelta
#endif
        browserOmnibarRepeatStartWorkItem?.cancel()
        browserOmnibarRepeatTickWorkItem?.cancel()
        browserOmnibarRepeatStartWorkItem = nil
        browserOmnibarRepeatTickWorkItem = nil
        browserOmnibarRepeatPanelId = nil
        browserOmnibarRepeatKeyCode = nil
        browserOmnibarRepeatDelta = 0
#if DEBUG
        if previousKeyCode != nil || previousDelta != 0 {
            cmuxDebugLog(
                "browser.focus.omnibar.repeat.stop panel=\(previousPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil") " +
                "key=\(previousKeyCode.map(String.init) ?? "nil") " +
                "delta=\(previousDelta)"
            )
        }
#endif
    }

    func handleBrowserOmnibarSelectionRepeatLifecycleEvent(_ event: NSEvent) {
        guard browserOmnibarRepeatKeyCode != nil else { return }

        switch event.type {
        case .keyUp:
            if event.keyCode == browserOmnibarRepeatKeyCode {
#if DEBUG
                cmuxDebugLog(
                    "browser.focus.omnibar.repeat.lifecycle event=keyUp key=\(event.keyCode) " +
                    "action=stop"
                )
#endif
                stopBrowserOmnibarSelectionRepeat()
            }
        case .flagsChanged:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !browserOmnibarShouldContinueControlNavigationRepeat(flags: flags) {
#if DEBUG
                cmuxDebugLog(
                    "browser.focus.omnibar.repeat.lifecycle event=flagsChanged " +
                    "flags=\(flags.rawValue) action=stop"
                )
#endif
                stopBrowserOmnibarSelectionRepeat()
            }
        default:
            break
        }
    }

    func isLikelyWebInspectorResponder(_ responder: NSResponder?) -> Bool {
        cmuxIsLikelyWebInspectorResponder(responder)
    }
#if DEBUG
    func developerToolsShortcutProbeKind(event: NSEvent) -> String? {
        guard event.type == .keyDown else { return nil }
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .toggleBrowserDeveloperTools)) {
            return "toggle.configured"
        }
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .showBrowserJavaScriptConsole)) {
            return "console.configured"
        }

        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .option] {
            if chars == "i" || event.keyCode == 34 {
                return "toggle.literal"
            }
            if chars == "c" || event.keyCode == 8 {
                return "console.literal"
            }
        }
        return nil
    }

    func logDeveloperToolsShortcutSnapshot(
        phase: String,
        event: NSEvent? = nil,
        didHandle: Bool? = nil
    ) {
        let keyWindow = NSApp.keyWindow
        let firstResponder = keyWindow?.firstResponder
        let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        let eventDescription = event.map(NSWindow.keyDescription) ?? "none"
        if let browser = tabManager?.focusedBrowserPanel {
            var line =
                "browser.devtools shortcut=\(phase) panel=\(browser.id.uuidString.prefix(5)) " +
                "\(browser.debugDeveloperToolsStateSummary()) \(browser.debugDeveloperToolsGeometrySummary()) " +
                "keyWin=\(keyWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) event=\(eventDescription)"
            if let didHandle {
                line += " handled=\(didHandle ? 1 : 0)"
            }
            cmuxDebugLog(line)
            return
        }
        var line =
            "browser.devtools shortcut=\(phase) panel=nil keyWin=\(keyWindow?.windowNumber ?? -1) " +
            "fr=\(firstResponderType)@\(firstResponderPtr) event=\(eventDescription)"
        if let didHandle {
            line += " handled=\(didHandle ? 1 : 0)"
        }
        cmuxDebugLog(line)
    }
#endif

}
