import AppKit
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextNotifications

/// Invite People (design chat-multiplayer.md 2): puts the CmuxNextNotifications
/// ``AgentShareInviteCard`` over the active window as a centered dialog, like Share cmux.
@MainActor
enum AgentShareInviteSheetPresenter {
    /// Shows the sheet over the active window and reads who is invited.
    static func present(_ model: AgentShareInviteSheetModel, services: AppServices) {
        let host = services.windows.active?.window.map(WindowOverlayHost.host(for:)) ?? WindowOverlayHost.appHost()
        let card = AgentShareInviteCard(model: model, closeImage: NSImage.icon(.actionClose, size: 12))
        let handle = host.present(card, options: .dialog())
        card.onClose = { [weak handle] in handle?.dismiss() }
        card.focusField()
        // task-owner: the sheet's first read of the chat's shares; ends with the read
        Task { await model.load() }
    }
}
