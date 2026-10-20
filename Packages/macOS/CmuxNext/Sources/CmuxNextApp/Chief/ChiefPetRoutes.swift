import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextFloating

/// What the Chief pet (`CmuxNextFloating`) opens and sends in this app; `NotificationCenterService+ChiefPet`
/// makes and feeds the pet. A click on the pet opens its reply box.
@MainActor
struct ChiefPetRoutes {
    weak var services: AppServices?

    func makePet() -> ChiefPetController {
        ChiefPetController(makePanel: { ChiefPetPanel() }, actions: ChiefPetActions(
            open: { open($0) }, send: { await send(to: $0, $1) }))
    }

    /// The Chief opens Home (`home.show`, as the palette does); a notice opens its tab as its banner click does.
    func open(_ target: ChiefPetReplyTarget) {
        guard let services else { return }
        guard case .notice(let notice) = target else {
            _ = services.registry.perform("home.show", invocation: ActionInvocation(origin: .user))
            return
        }
        services.notifications.open(surface: notice.surface.map(SurfaceID.init(rawValue:)))
    }

    /// A message to the Chief's conversation (this Mac's or a paired server's), or a reply typed into a terminal.
    func send(to target: ChiefPetReplyTarget, _ text: String) async -> Bool {
        guard let services else { return false }
        guard case .notice(let notice) = target else {
            guard let chief = TopHomePageView.chief(services.home) else { return false }
            return (try? await services.home.homeStore.send(conversation: ConversationID(chief), text: text, attachments: [])) != nil
        }
        return await services.notifications.typeChiefPetReply(text, to: notice)
    }
}
