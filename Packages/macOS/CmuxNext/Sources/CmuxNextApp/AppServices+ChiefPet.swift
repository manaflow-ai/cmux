import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextFloating

extension AppServices {
    /// The Chief pet floats over every app (`CmuxNextFloating`). Its bubble shows what alerts here
    /// (`NotificationCenterService+ChiefPet`); a click on the pet opens its reply box.
    func makeChiefPet() -> ChiefPetController {
        ChiefPetController(makePanel: { ChiefPetPanel() }, actions: ChiefPetActions(
            open: { [weak self] in self?.openChiefPetTarget($0) }, send: { [weak self] in await self?.sendChiefPetReply(to: $0, $1) ?? false }))
    }

    /// The Chief opens Home (`home.show`, as the palette does); an agent chat opens in the floating chat
    /// when that is on, and any other notice's tab as its banner click does.
    private func openChiefPetTarget(_ target: ChiefPetReplyTarget) {
        guard case .notice(let notice) = target else {
            _ = registry.perform("home.show", invocation: ActionInvocation(origin: .user))
            return
        }
        if notice.reply == .openChat, let session = notice.session, quickComposer.moveToFloatingChat(session: session) { return }
        notifications.open(surface: notice.surface)
    }

    /// A message to the Chief's conversation (this Mac's or a paired server's), or a reply typed into a terminal.
    private func sendChiefPetReply(to target: ChiefPetReplyTarget, _ text: String) async -> Bool {
        guard case .notice(let notice) = target else {
            guard let chief = TopHomePageView.chief(home) else { return false }
            return (try? await home.homeStore.send(conversation: ConversationID(chief), text: text, attachments: [])) != nil
        }
        guard let surface = notice.surface, let located = notifications.locate(surface: surface, in: daemon.store) else { return false }
        return notifications.type(text, into: located)
    }
}
