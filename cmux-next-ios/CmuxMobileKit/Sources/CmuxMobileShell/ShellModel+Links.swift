#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileChief
import CmuxMobileDesign
import CmuxMobileModel
import OSLog
import SwiftUI

private let theme = CmuxMobileTheme.standard
private let linkLog = Logger(subsystem: "dev.cmux.mobile", category: "links")

extension NotificationTarget {
    /// Where a cmux link opens, from what the phone knows now: the workspace
    /// or tab it names (matched by the Mac's public ids), the chat of a
    /// session, Chief for a Home conversation. Nil while nothing the phone
    /// lists matches it.
    ///
    /// - `workspaces`: every workspace the phone lists.
    /// - `chat`: the chat an acpmux session id is bound to, when known.
    static func resolve(_ link: CmuxLink, workspaces: [Workspace],
                        chat: (String) -> AgentChatDestination?) -> NotificationTarget? {
        func workspace(_ resourceID: String) -> Workspace? {
            workspaces.first { $0.resourceID == resourceID }
        }
        func tab(where matches: (WorkspaceTab) -> Bool) -> (Workspace, WorkspaceTab)? {
            for workspace in workspaces {
                if let tab = workspace.tabs.first(where: matches) { return (workspace, tab) }
            }
            return nil
        }
        switch link.target {
        case .workspace(let id):
            return workspace(id).map { .workspace(id: $0.id, tabID: nil) }
        case .pane(let id):
            // The pane's selected tab, else its first one the phone lists.
            let found = tab { $0.linkIDs?.pane == id && $0.linkIDs?.isPaneSelected == true } ?? tab { $0.linkIDs?.pane == id }
            return found.map { .workspace(id: $0.0.id, tabID: $0.1.id) }
        case .tab(let id):
            return tab { $0.linkIDs?.tab == id }.map { .workspace(id: $0.0.id, tabID: $0.1.id) }
        case .session(let session, _), .chiefSession(_, let session):
            return chat(session).map { .chat($0) }
        case .agent(let harness, let session):
            // As the Mac's `DeepLink.agentTabs`: the chat bound to the session, else a terminal
            // whose agent reports it under that harness, else one whose agent names no harness
            // we know (a Claude Code subagent reports its type). Another harness's never.
            if let destination = chat(session) { return .chat(destination) }
            let running = tab { $0.linkIDs?.harnessSession == session && knownHarness($0.harness) == harness }
                ?? tab { $0.linkIDs?.harnessSession == session && knownHarness($0.harness) == nil }
            return running.map { .workspace(id: $0.0.id, tabID: $0.1.id) }
        case .group(_, let id):
            guard let id else { return .workspaces }
            return workspace(id).map { .workspace(id: $0.id, tabID: nil) }
        case .conversation(let conversationID, _):
            // The same destination as a Chief notification, which already
            // knows how to open a named Cloud or Mac Home conversation.
            return .chief(conversationID: conversationID)
        }
    }

    /// Home links carry only the conversation id. Resolve it against the
    /// currently loaded Cloud Chief, Mac Chief and Mac Home list; an absent
    /// conversation is never silently replaced with a different Chief.
    static func knowsHomeConversation(_ id: String, macChief: String?, cloudChief: String?,
                                      homeChief: String?, homeRows: Set<String>) -> Bool {
        id == macChief || id == cloudChief || id == homeChief || homeRows.contains(id)
    }

    /// The harness a reported agent names, or nil for one we do not know
    /// (the Mac's `DeepLink.knownHarness`; Claude Code's hooks may say `claude-code`).
    static func knownHarness(_ agent: String?) -> String? {
        guard let agent = agent?.lowercased() else { return nil }
        if agent == "claude-code" { return "claude" }
        return ["claude", "codex", "opencode", "gemini", "muse"].contains(agent) ? agent : nil
    }

    /// Said when a link names nothing the phone lists (its Mac is offline, the
    /// tab closed, or it is on another account's Mac).
    static func linkNotFoundToast() -> CmuxMobileToast {
        CmuxMobileToast(symbol: "link", text: String(localized: "Couldn't find that link on your Macs."))
    }
}

extension ShellModel {
    /// ``openRoute(_:)`` for a link: false while it may still appear (a Mac's
    /// tree is on its way), else opens it, or says it was not found and
    /// stays where the person is.
    func openLink(_ link: CmuxLink) -> Bool {
        // A link decides where the app opens: a launch restore never lands over it.
        cancelRestore()
        let target = NotificationTarget.resolve(link, workspaces: store.activeWorkspaces) { [live] session in
            live?.destination(sessionID: session, workspaceID: nil, tabID: nil)
        }
        if case .conversation(let conversationID, _) = link.target {
            let sources = ChiefSources.shared
            let feed = MacHomeFeed.shared
            let known = NotificationTarget.knowsHomeConversation(
                conversationID, macChief: sources.mac.conversationID, cloudChief: sources.cloud.conversationID,
                homeChief: feed.macChiefID, homeRows: Set(feed.rows?.map(\.id) ?? []))
            if !known {
                // The Mac Home list and Cloud Chief may still be loading on a
                // cold launch. Wait for the route's bounded budget, then say
                // which link failed instead of opening an unrelated Chief.
                if !NotificationRouter.shared.isExpired() { return false }
                toast = NotificationTarget.linkNotFoundToast()
                theme.haptics.error()
                return true
            }
        }
        guard let target else {
            if !NotificationRouter.shared.isExpired(), macsStillLoading { return false }
            linkLog.info("cmux link (\(link.kind, privacy: .public)) names nothing this phone lists")
            toast = NotificationTarget.linkNotFoundToast()
            theme.haptics.error()
            return true
        }
        linkLog.info("cmux link (\(link.kind, privacy: .public)) opens \(String(describing: target), privacy: .private)")
        open(target: target)
        return true
    }

    /// Whether a Mac of the active team is answering now (its tree is on the
    /// way), or the live link is not attached yet. An idle Mac nothing dials is
    /// not waited for.
    private var macsStillLoading: Bool {
        guard !mockMode else { return false }
        if live == nil, auth.isSignedIn { return true }
        return (store.activeTeam?.macs ?? []).contains { mac in
            switch store.macDataPhase(mac.id) {
            case .loading, .cached(.connecting): true
            default: false
            }
        }
    }
}
#endif
