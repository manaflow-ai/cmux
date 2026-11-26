import CmuxNextActions
import CmuxNextDevices

/// The viewer toolbar's controls as palette rows. Each one runs the handler its toolbar button,
/// menu item or card button runs (``MacScreenChromeActions``), on the targeted or selected Screen
/// Sharing tab. Each is unavailable, with its reason, where the toolbar hides it or turns it off.
enum MacScreenViewerControl: CaseIterable {
    case viewOnly, fullControl, fullScreen, sendSwitchApp, sendSpotlight, reconnect

    var actionID: ActionID {
        switch self {
        case .viewOnly: "macScreen.viewOnly"
        case .fullControl: "macScreen.fullControl"
        case .fullScreen: "macScreen.fullScreen"
        case .sendSwitchApp: "macScreen.sendSwitchApp"
        case .sendSpotlight: "macScreen.sendSpotlight"
        case .reconnect: "macScreen.reconnect"
        }
    }

    /// Why this control can't run on a tab whose model is `model` (nil: no Screen Sharing tab), or nil when it can.
    /// It is the toolbar's rule: the access menu, Full Screen and Send Keys show only while a session streams, Send Keys
    /// is off in a View Only session, and Reconnect is the card's Reconnect, Try Again or Connect Again.
    @MainActor func unavailableReason(_ model: MacScreenPaneModel?) -> String? {
        guard let model else { return self == .reconnect ? Self.noReconnect : Self.noStream }
        let streaming = model.showsSessionControls
        switch self {
        case .viewOnly, .fullControl:
            guard streaming, let current = model.hub?.phase.streamingScope else { return Self.noStream }
            return current == scope ? String(format: L.t("macScreen.actions.alreadyScope", "This Screen Sharing session already uses %@."), current.title) : nil
        case .fullScreen:
            return streaming ? nil : Self.noStream
        case .sendSwitchApp, .sendSpotlight:
            guard streaming, model.isLive else { return Self.noStream }
            return model.canSendKeys ? nil : L.t("macScreen.toolbar.sendKeysViewOnly", "Send Keys is off in a View Only session")
        case .reconnect:
            return model.offersReconnect ? nil : Self.noReconnect
        }
    }

    /// Runs the control's existing handler.
    @MainActor func run(_ actions: MacScreenChromeActions) {
        switch self {
        case .viewOnly, .fullControl: actions.requestScope(scope)
        case .fullScreen: actions.fullScreen()
        case .sendSwitchApp, .sendSpotlight:
            if let shortcut = MacScreenShortcut.all.first(where: { $0.id == shortcutID }) { actions.sendKeys(shortcut) }
        case .reconnect: actions.connect()
        }
    }

    private var scope: SessionScope { self == .viewOnly ? .view : .full }
    /// The Send Keys menu's item.
    var shortcutID: String? {
        switch self {
        case .sendSwitchApp: "switchApp"
        case .sendSpotlight: "spotlight"
        default: nil
        }
    }

    static var noStream: String { L.t("macScreen.actions.noStream", "Choose a Screen Sharing tab that is showing a screen.") }
    // retry-prompt-ok: a palette command's refusal (no disconnected tab to reconnect), not a retry prompt
    static var noReconnect: String { L.t("macScreen.actions.noReconnect", "Choose a disconnected Screen Sharing tab to reconnect.") }
}

extension MacScreenActions {
    /// Binds the viewer's controls and Stop Viewing All Shared Screens. Until the app's pinned catalog lists an id,
    /// its bind does nothing (``ActionRegistry/bindEffect(_:effect:)`` returns false).
    func bindViewerControls(into registry: ActionRegistry) {
        for control in MacScreenViewerControl.allCases {
            // The gate refuses every run (palette, CLI, MCP) while it gives a reason, so a run has its tab.
            registry.bindEffect(control.actionID, effect: { invocation in
                if let pane = screenTab(invocation) { control.run(pane.view.chrome.actions) }
                return .done
            })
            ActionTargetVisibility.gate(control.actionID, in: registry) { unavailableReason(control, $0) }
        }
        registry.bindEffect("macScreen.stopAllViewing", unavailable: { pages.viewingPanes.isEmpty ? Self.noSessions : nil }, effect: { _ in
            for pane in pages.viewingPanes { pane.disconnectByPerson() }
            return .done
        })
    }

    /// Why `control` can't run on `invocation`'s tab. Full Screen also needs the tab shown in a window (it toggles that window).
    func unavailableReason(_ control: MacScreenViewerControl, _ invocation: ActionInvocation) -> String? {
        let pane = screenTab(invocation)
        if let reason = control.unavailableReason(pane?.model) { return reason }
        return control == .fullScreen && pane?.view.window == nil ? MacScreenViewerControl.noStream : nil
    }

    private static var noSessions: String { L.t("macScreen.actions.noSessions", "No Screen Sharing session is open.") }
}

extension MacScreenPages {
    /// The tabs viewing another device: asking, waiting for approval or streaming (Stop Viewing's tabs).
    var viewingPanes: [MacScreenPane] {
        tabs.values.sorted { $0.key < $1.key }.compactMap(\.pane).filter { pane in
            guard let phase = pane.model.hub?.phase else { return false }
            return phase.isPending || phase.streamingScope != nil
        }
    }
}

extension MacScreenPaneModel {
    /// The state could be answered by Reconnect, Try Again or Connect Again (each runs ``MacScreenChromeActions/connect``),
    /// whether the card shows that button or the pane retries on its own (the palette's Reconnect then asks now).
    var offersReconnect: Bool {
        guard hub != nil else { return false }
        switch stateCard {
        case .failed?, .ended?: return true
        case let .hubRevoked(reason)?, let .hubEnded(reason)?: return reason.canReconnect
        default: return false
        }
    }
}
