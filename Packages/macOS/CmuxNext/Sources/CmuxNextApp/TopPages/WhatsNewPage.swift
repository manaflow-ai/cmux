import AppKit
import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextSidebar
import CmuxNextUpdater

/// What's New after an update (WHATS-NEW-AFTER-UPDATE W1): the React changelog page
/// (``ChangelogPageTab``), opened by the bottom-left "cmux Updated!" card, the palette, the Help
/// menu and `updates.whatsNew`. It has no sidebar item at the top (Lawrence 2026-10-18). The native SwiftUI page
/// went with react-screens.md; the center (`WhatsNewCenter`) still tracks what is unseen.
@MainActor
enum WhatsNewPage {
    /// Opens the changelog on this build (the span of the unseen notes) and marks every version up
    /// to this one seen. A run that may not change the view (automation) opens nothing and leaves
    /// the item.
    @discardableResult
    static func open(_ services: AppServices, in state: WindowState? = nil) -> Bool {
        // Not behind Labs (Leo, 2026-10-29: "why the fuck does See What's New not fucking open the
        // What's New tab anymore"; 2026-10-30: "i dont like putting so much stuff in labs").
        guard ActionRunScope.viewChangeAllowed() else { return false }
        let center = services.updater.whatsNew
        // The span starts at the version seen before this update (read before `open` marks seen).
        let from = center.lastSeen.flatMap { seen in center.current.map { seen < $0 } == true ? seen : nil }
        center.open()
        return ChangelogPageTab.open(services, focus: true, from: from?.description, to: center.current?.description)
    }

    /// A click on a client-only sidebar item: the Channels entry switches Home to Channels; a
    /// Chief subagent row opens its chat. Other machines' chats draw no rows (`RemoteMachinesSidebar` is not bound).
    static func activateClientItem(_ id: LayoutItemID, services: AppServices, in state: WindowState?) {
        if ChiefSidebar.shared.activate(id, registry: services.registry) { return }
        // The Channels entry after Home (cx-frn2y): the one Home view path, as a person's click.
        if id == SidebarTransientItem.channelsID { _ = services.registry.perform("home.switchView", invocation: .init(arguments: ["view": .string("channels")], origin: .user)) }
    }
}
