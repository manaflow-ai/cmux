import CmuxHomeCore
import CmuxNextActions
import CmuxNextHomeEngine
import Foundation

/// The Chief's first-launch welcome (#26053, ``ChiefWelcome``): one message from the Chief in this
/// Chief home's conversation, with the shortcuts as the registry shows them when it is written.
extension HomeService {
    /// The shortcuts the welcome lists under its ⌘P call-out, in order.
    static let welcomeShortcuts: [ActionID] = ["commandPalette", "search.chats", "newTab.default", "newSurface", "palette.newAgentChat"]
    /// The action the welcome calls out first (⌘P).
    static let welcomeGoTo: ActionID = "goToWorkspace"

    /// Runs the welcome on each connection of the Chief owner, after the old Chiefs' migration and
    /// before Home attaches (`ChiefConversationOwner.prepare`). Isolated Chief homes (agent
    /// preflights, captures) get none unless `CMUX_NEXT_CHIEF_WELCOME=1`.
    func installChiefWelcome() {
        let home = chief.home
        guard !home.isolated || ProcessInfo.processInfo.environment["CMUX_NEXT_CHIEF_WELCOME"] == "1" else { return }
        let welcome = ChiefWelcome(home: home, chief: Self.mux.id)
        let create = HomeChiefName.createRequest(user: Self.localUser, mux: Self.mux)
        let registry = services.registry
        let logger = logger
        let earlier = chief.prepare
        chief.prepare = { [weak self] connection in
            if let earlier { await earlier(connection) }
            var record = await welcome.load()
            if record == nil {
                let text = await MainActor.run { Self.welcomeText(registry) }
                record = await welcome.run(owner: ChiefWelcome.Owner(connection: connection, create: create), text: text)
                if record == nil { logger.info("chief welcome: not posted on this connection; the next one tries again") }
            }
            await MainActor.run { self?.chiefWelcome = record }
        }
    }

    /// Whether the conversation `id` (newest seq `lastSeq`) holds only the welcome: Home treats it as empty.
    func isOnlyWelcome(_ id: String, lastSeq: UInt64) -> Bool {
        chiefWelcome?.isOnlyMessage(of: id, lastSeq: lastSeq) == true
    }

    /// The same for a summary of the Home store.
    func isOnlyWelcome(_ summary: CmuxHomeCore.ConversationSummary) -> Bool {
        isOnlyWelcome(summary.id.rawValue, lastSeq: summary.lastSeq)
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
