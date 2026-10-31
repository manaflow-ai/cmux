import CmuxHomeCore
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextHome
import CmuxNextHomeEngine
import Foundation

/// Send Message from anywhere (HomeMessageActionCatalog; u5402, Oct 20: "Make sure we can send
/// messages in the iMessage UI via right clicking"). Every entry point resolves its chat with
/// `HomeService.messageRouting`, then either writes the message box of that chat and opens it
/// with the box focused (the person reads and presses Return: the Home chat's own send and
/// order, home-chat-pipeline-DESIGN.md), or, given text from `cmux chat send` or MCP, sends it
/// through the same `HomeGroupActions.send`. Nothing here orders or streams messages.
extension AppActions {
    static func bindHomeMessaging(_ services: AppServices) {
        let registry = services.registry
        let suggestions = registry.argumentSuggestions
        registry.argumentSuggestions = { [weak services] source in
            guard let home = services?.home else { return suggestions?(source) ?? [] }
            return home.messageRouting.suggestions(for: source, members: home.chiefRoster.groupMembers(home.contacts(), rows: home.homeStore.rows, excluding: home.homeStore.me?.id)) ?? suggestions?(source) ?? []
        }
        registry.bind("home.messageTo", invoke: { invocation in
            let routing = services.home.messageRouting
            let to = invocation["to"]?.stringValue ?? ""
            guard let id = routing.resolve(to) else {
                return registry.refuse(HomeGroupOutcome.unknownConversation.message ?? RefusalStrings.homeNotReady)
            }
            let text = invocation["text"]?.stringValue ?? ""
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return trackSend(services) { await routing.send(text, to: id) }
            }
            openToWrite(id, draft: nil, services)
        })
        registry.bind("home.messageAbout", invoke: { invocation in
            let routing = services.home.messageRouting
            guard let chief = routing.chiefConversation else { return registry.refuse(RefusalStrings.homeNotReady) }
            guard let mention = mention(of: invocation, services) else { return }
            openToWrite(chief, draft: routing.compose(mention, into: chief), services)
        })
        registry.bind("home.sendSelectionToChief", invoke: { invocation in
            let routing = services.home.messageRouting
            guard let text = selection(invocation, services) else { return }
            guard let chief = routing.chiefConversation else { return registry.refuse(RefusalStrings.homeNotReady) }
            openToWrite(chief, draft: routing.compose(HomeMessageRouting.quoted(text), into: chief), services)
        })
        registry.bind("home.sendSelectionTo", invoke: { invocation in
            let routing = services.home.messageRouting
            guard let text = selection(invocation, services) else { return }
            guard let id = routing.resolve(invocation["to"]?.stringValue ?? "") else {
                return registry.refuse(HomeGroupOutcome.unknownConversation.message ?? RefusalStrings.homeNotReady)
            }
            openToWrite(id, draft: routing.compose(HomeMessageRouting.quoted(text), into: id), services)
        })
    }

    /// Opens `id` through `home.openConversation` (the path a row click takes: shown, message box
    /// focused). `draft` is already the store's draft of `id`: a new view restores it, the view
    /// that shows `id` now takes it at once.
    private static func openToWrite(_ id: ConversationID, draft: String?, _ services: AppServices) {
        services.registry.perform("home.openConversation",
                                  invocation: ActionInvocation(arguments: ["conversation": .string(id.rawValue)], origin: .user))
        guard let draft, let page = shownPage(services), page.shown == id, let host = page.host,
              let transcript = HomePageTab.transcript(in: host) else { return }
        transcript.showDraft(draft)
    }

    /// The text a selection row sends: the menu's `text` (a page, Markdown, a bubble), else the
    /// right-clicked terminal's selection; refused when nothing is selected.
    private static func selection(_ invocation: ActionInvocation, _ services: AppServices) -> String? {
        if let text = invocation["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        let ctx = AppActionContext(services: services)
        if let entry = ctx.terminal(invocation), let text = TerminalHandlers.selection(of: entry) { return text }
        services.registry.refuse(RefusalStrings.nothingSelected)
        return nil
    }

    /// A link chip naming the right-clicked tab (an agent chat's session link) or workspace.
    private static func mention(of invocation: ActionInvocation, _ services: AppServices) -> String? {
        let ctx = AppActionContext(services: services)
        do {
            if invocation.target?.kind == .tab || invocation["tab"]?.targetValue != nil {
                if let key = LinkHandlers.agentTab(invocation, services: services) {
                    let title = ctx.daemonTab(invocation)?.tab.displayTitle ?? ""
                    return HomeMessageRouting.mention(title, link: try services.link(agentTab: key))
                }
                if let (tab, _) = ctx.daemonTab(invocation) {
                    return HomeMessageRouting.mention(tab.displayTitle, link: try services.link(tab: tab))
                }
            }
            let workspace = try ctx.workspace(invocation).model
            return HomeMessageRouting.mention(workspace.title ?? "", link: try services.link(workspace: workspace))
        } catch let failure as ActionFailure {
            services.registry.refuse(failure.message)
        } catch {
            services.registry.refuse(RefusalStrings.homeNotReady)
        }
        return nil
    }

    /// A send the caller (socket, CLI, MCP) waits for; a refusal is its failure.
    private static func trackSend(_ services: AppServices, _ body: @escaping @MainActor () async -> HomeGroupOutcome) {
        services.registry.track(ActionWork {
            let outcome = await body()
            guard !outcome.succeeded else { return nil }
            let refusal: ActionWorkRefusal = outcome == .unknownConversation ? .notFound : .unavailable
            return ActionWorkFailure(refusal: refusal, reason: outcome.message ?? "")
        })
    }
}
