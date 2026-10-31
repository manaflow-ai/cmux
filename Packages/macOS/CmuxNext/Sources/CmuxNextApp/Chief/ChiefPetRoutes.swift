import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextChiefPetWiring
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFloating
import CmuxNextSettings

/// What the Chief pet (`CmuxNextFloating`) opens and sends in this app; `NotificationCenterService+ChiefPet`
/// makes and feeds the pet. A click on the pet opens its reply box; its menu opens its settings or hides it.
@MainActor
struct ChiefPetRoutes {
    weak var services: AppServices?

    func makePet() -> ChiefPetController {
        // The notices' card shows over cmux only; over another app the pet's badge counts what waits.
        ChiefPetController(makePanel: { ChiefPetPanel() }, actions: ChiefPetActions(
            registry: services?.registry, open: { open($0) }, send: { await send(to: $0, $1) }, openSettings: { openSettings() }),
            appIsActive: { services?.appActiveSource() ?? false })
    }

    /// Chief Pet Settings…: the Chief Settings popover over a Chief's Home on screen (its
    /// Appearance rows), else Settings on Show Chief Pet. The pet never activates cmux; this does.
    func openSettings() {
        guard let services, !services.chiefPetHomes.open(noActivate: services.environment.noActivate) else { return }
        try? services.settingsWindow.show(section: nil, setting: HomeChiefPetSetting.configPath.joined(separator: "."), focus: true)
        if let window = services.windows.active?.window { WindowActivation.show(window, services.environment.noActivate ? .raise : .focus) }
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
