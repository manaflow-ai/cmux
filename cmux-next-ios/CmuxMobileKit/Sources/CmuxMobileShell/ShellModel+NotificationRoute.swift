#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileChief
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

/// Where a tapped notification opens (verify/rich-push.md, "Tap routing"),
/// decided from what the phone knows now.
enum NotificationTarget: Equatable {
    /// That Mac's Chief conversation, on Home.
    case chief
    /// The agent's chat.
    case chat(AgentChatDestination)
    /// A workspace at one of its tabs: a terminal, a browser tab, an agent tab.
    case workspace(id: String, tabID: String?)
    /// The Mac's tree has not arrived yet: try again when it does.
    case wait
    /// Nothing more exact is known: the Feed.
    case feed

    /// - `chat`: the chat a session or a tab is bound to, when known.
    /// - `workspace`: the workspace (with its Mac) that lists `tabID`, when known.
    /// - `phase`: the route's Mac's data phase.
    /// - `canLink`: whether the phone may dial the route's Mac at all.
    /// - `expired`: the route waited its whole budget (`NotificationRouter.waitBudget`).
    static func decide(_ route: NotificationRoute,
                       chat: (NotificationRoute) -> AgentChatDestination?,
                       workspace: (String) -> Workspace?,
                       phase: (String) -> MacDataMachine.Phase,
                       canLink: (String) -> Bool,
                       expired: Bool) -> NotificationTarget {
        if route.kind == "chief" { return .chief }
        // A terminal notification opens its terminal, never a chat bound elsewhere.
        // A terminal agent's event (no acpmux session, its terminal's tab) opens its terminal too.
        let terminalTab = route.sessionID == nil && route.workspaceID.flatMap(workspace)?.tabs
            .contains { $0.id == route.tabID && $0.kind == .terminal } == true
        if route.kind != "terminal", !terminalTab, let destination = chat(route) { return .chat(destination) }
        if let id = route.workspaceID, let ws = workspace(id), route.mac == nil || ws.macID == route.mac {
            let tab = route.tabID.flatMap { tab in ws.tabs.contains(where: { $0.id == tab }) ? tab : nil }
            if tab != nil || route.kind == "terminal" || route.tabID == nil { return .workspace(id: ws.id, tabID: tab) }
        }
        guard let mac = route.mac, !expired else { return .feed }
        // Wait only while the Mac's tree can still arrive (review #4).
        switch phase(mac) {
        case .live, .empty, .failed, .offline: return .feed
        case .cached(.offline), .cached(.failed): return .feed
        case .idle: return canLink(mac) ? .wait : .feed
        case .loading, .cached: return .wait
        }
    }
}

extension ShellModel {
    /// Opens a tapped notification on its Mac: Chief's reply on Home, an
    /// agent's event in its chat, a terminal (or browser) notification at its
    /// tab. Returns false while the Mac's tree has not arrived, so the shell
    /// tries again when it does.
    func openRoute(_ route: NotificationRoute) -> Bool {
        // Signed in, but the live link is not attached yet (a cold launch while
        // the account settles): no Mac's tree can be read, so `decide` would
        // settle for the Feed. Wait instead; ShellView tries again once the link is
        // attached (and on each tree change), and the
        // route's budget still ends the wait.
        if route.mac != nil, live == nil, !mockMode, auth.isSignedIn, !NotificationRouter.shared.isExpired() {
            tab = .feed
            return false
        }
        // The notification's Mac (one link per Mac): its link opens now if it
        // was idle, so the chat and its answers reach that Mac. Chief follows
        // the focused Mac, so a Chief notification also moves the focus there.
        if let mac = route.mac, !mac.isEmpty, let live, live.canLink(macID: mac) {
            if route.kind == "chief", live.focusedMacID != mac { live.select(macID: mac) } else { live.touch(mac) }
        }
        let target = NotificationTarget.decide(
            route,
            chat: { [live] in live?.destination(sessionID: $0.sessionID, workspaceID: $0.workspaceID, tabID: $0.tabID) },
            workspace: { [store] in store.workspace(id: $0) },
            phase: { [store] in store.macDataPhase($0) },
            canLink: { [live] in live?.canLink(macID: $0) ?? false },
            expired: NotificationRouter.shared.isExpired()
        )
        switch target {
        case .chief:
            tab = .home
            var path = NavigationPath()
            path.append(ChiefRoute(place: .mac))
            homePath = path
        case .chat(let destination):
            tab = .feed
            feedPath = [destination]
        case .workspace(let id, let tabID):
            guard let workspace = store.workspace(id: id) else {
                // Defensive only: `decide` read this same store a moment ago on the
                // main actor. Should it ever be gone, the Feed, never a wait.
                tab = .feed
                toast = NotificationTarget.fallbackToast(route, macName: macName(route.mac))
                return true
            }
            if let tabID { store.noteOpened(tabID: tabID, in: workspace.id) }
            store.markSeen(workspace.id)
            tab = .workspaces
            if workspacesPath.last?.id == workspace.id {
                // Its page is already up, maybe on another tab: build it again on this one.
                workspacesPath = []
                Task { @MainActor [weak self] in self?.workspacesPath = [workspace] }
            } else {
                workspacesPath = [workspace]
            }
        case .wait:
            tab = .feed
            return false
        case .feed:
            tab = .feed
            toast = NotificationTarget.fallbackToast(route, macName: macName(route.mac))
        }
        return true
    }

    private func macName(_ id: String?) -> String? {
        guard let id else { return nil }
        return store.teams.flatMap(\.macs).first { $0.id == id }?.name
    }
}

extension NotificationTarget {
    /// Said when a tap that named a chat, workspace or tab settles for the Feed
    /// (the screen is gone, its Mac is offline, or its tree never came): the
    /// person sees why the exact screen did not open. Nil when the Feed is what
    /// the notification points at.
    static func fallbackToast(_ route: NotificationRoute, macName: String?) -> CmuxMobileToast? {
        guard route.kind != "chief", route.sessionID != nil || route.workspaceID != nil || route.tabID != nil else { return nil }
        let mac = macName ?? String(localized: "your Mac")
        return CmuxMobileToast(symbol: "exclamationmark.circle", text: String(localized: "Couldn't open that on \(mac). Showing the Feed."))
    }
}
#endif
