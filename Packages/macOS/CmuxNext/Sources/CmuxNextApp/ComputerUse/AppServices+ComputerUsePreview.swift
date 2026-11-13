import AppKit
import CmuxNextComputerUse
import CmuxNextMacScreen

/// What the live preview of an agent's Computer Use reads from the App (ComputerUsePreviewPresenter).
extension AppServices: ComputerUsePreviewHost {
    var computerUseLivePreviewEnabled: Bool { settings?.snapshot.computerUse.livePreview ?? true }

    /// The focused tab of the key window's shown workspace while cmux is active: an agent's terminal
    /// (its cmux terminal id) or an agent chat (its acpmux session), with its view.
    func computerUsePreviewFocus() -> (surface: ComputerUsePreviewSurface, host: NSView)? {
        guard appActiveSource(), let controller = windows.active, controller.window?.isKeyWindow == true,
              let focus = NotificationCenterService.shownFocus(controller) else { return nil }
        if case .terminal(_, let tab) = focus, let resource = daemon.store.tab(id: tab)?.terminalResourceID?.rawValue,
           let view = cache.existingTerminal(tab)?.session.view { return (.terminal(resource: resource), view) }
        if case .agentPage(_, let tab) = focus, let session = agentTabs.session(of: tab),
           let key = agentTabs.views.onlyKey(ofTab: tab), let view = agentTabs.views[key] { return (.chat(session: session), view) }
        return nil
    }
}
