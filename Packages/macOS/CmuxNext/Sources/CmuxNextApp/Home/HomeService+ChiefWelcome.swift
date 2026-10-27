import CmuxNextActions
import CmuxNextDaemon
import CmuxNextHomeEngine
import Foundation

/// The Chief's first-launch welcome (#26053, ``ChiefWelcome``): written once into this Mac's
/// Chief conversation while it has no messages, with the shortcuts as the registry shows them now.
extension HomeService {
    /// The shortcuts the welcome lists under its ⌘P call-out, in order.
    static let welcomeShortcuts: [ActionID] = ["commandPalette", "search.chats", "newTab.default", "newSurface", "palette.newAgentChat"]
    /// The action the welcome calls out first (⌘P).
    static let welcomeGoTo: ActionID = "goToWorkspace"

    /// Posts the welcome into the local Chief conversation `id` (newest seq `lastSeq`) when due.
    func postChiefWelcome(_ owner: DaemonConnection, conversation id: String, lastSeq: UInt64, defaults: UserDefaults = .standard) async {
        let welcome = ChiefWelcome(defaults: defaults, chief: Self.mux.id)
        guard !welcome.posted else { return }
        let registry = services.registry
        let step = await welcome.run(conversation: id, lastSeq: lastSeq, text: { Self.welcomeText(registry) }) { request in
            _ = try await ConversationClient(owner).importHistory(request)
        }
        if step == .wait { logger.error("chief welcome: the import failed; the next connection tries again") }
    }

    /// The welcome's text with `registry`'s shortcuts (an unbound action is left out).
    static func welcomeText(_ registry: ActionRegistry) -> String {
        let shortcuts = welcomeShortcuts.compactMap { id -> ChiefWelcome.Shortcut? in
            guard let keys = registry.shortcutDisplay(for: id), let title = registry.descriptor(for: id)?.title else { return nil }
            return ChiefWelcome.Shortcut(keys: keys, title: title.hasSuffix("…") ? String(title.dropLast()) : title)
        }
        return ChiefWelcome.text(goTo: registry.shortcutDisplay(for: welcomeGoTo), shortcuts: shortcuts)
    }
}
