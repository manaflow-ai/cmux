import CmuxHomeCore
import CmuxNextActions
import CmuxNextHome
import CmuxNextHomeEngine
import Foundation

/// The DM and group actions (HomeActionCatalog: Conversation Info, Rename, Add People, Remove,
/// Leave, Hide and Show Alerts, Send): one path for the palette, `cmux home …`, MCP, the Home row
/// menu and the group info sheet, all through `HomeService.groupActions`. Each takes
/// `conversation` (an id); without it, the conversation the Home page shows. A run that waits
/// (`action.run` with `wait`, the CLI) gets the owner's refusal as its failure.
extension AppActions {
    static func bindHomeGroups(_ services: AppServices) {
        let registry = services.registry
        registry.bind("home.conversationInfo", invoke: { invocation in
            guard let id = conversation(invocation, services) else { return }
            guard services.home.dock.isClassic else {
                return withDock(services) { dock in
                    guard let page = dock.messages else { return services.registry.refuse(RefusalStrings.homeNotReady) }
                    page.presentGroupInfo(id)
                }
            }
            homePage(services)?.presentGroupInfo(id)
        })
        registry.bind("home.renameConversation", invoke: { invocation in
            guard let id = conversation(invocation, services) else { return }
            let title = invocation["title"]?.stringValue ?? ""
            runGroup(services) { await $0.rename(id, to: title) }
        })
        registry.bind("home.addMembers", invoke: { invocation in
            guard let id = conversation(invocation, services) else { return }
            let people = invocation["people"]?.stringValue ?? ""
            runGroup(services) { await $0.add(named: people, to: id) }
        })
        registry.bind("home.removeMember", invoke: { invocation in
            guard let id = conversation(invocation, services) else { return }
            let person = invocation["person"]?.stringValue ?? ""
            runGroup(services) { await $0.remove(named: person, from: id) }
        })
        registry.bind("home.leaveConversation", invoke: { invocation in
            guard let id = conversation(invocation, services) else { return }
            // The page showing it moves to its neighbor once the owner took the leave.
            let page = shownPage(services)
            let next = page.flatMap { $0.shown == id ? $0.sidebar.model().neighbor(of: id, offset: 1) : nil }
            runGroup(services) { actions in
                let outcome = await actions.leave(id)
                if outcome == .left, let page, page.shown == id { page.conversationLeft(id, next: next) }
                return outcome
            }
        })
        for (action, on) in [("home.muteConversation", true), ("home.unmuteConversation", false)] as [(ActionID, Bool)] {
            registry.bind(action, invoke: { invocation in
                guard let id = conversation(invocation, services) else { return }
                let outcome = services.home.groupActions.setMuted(on, id)
                if let message = outcome.message { registry.refuse(message) }
            })
        }
        // Group chats with Chiefs (chief-group-chats-DESIGN.md): the CLI and MCP get the new
        // group's id back; a person's run (palette) also shows it on the Home page.
        registry.bind("home.createGroup", invoke: { invocation in
            let members = invocation["members"]?.stringValue ?? ""
            let title = invocation["title"]?.stringValue ?? ""
            var replies: ChiefReplyPolicy?
            if let text = invocation["replies"]?.stringValue, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let parsed = ChiefReplyPolicy(argument: text) else {
                    return registry.refuse(HomeGroupOutcome.refused("").message ?? "")
                }
                replies = parsed
            }
            let actions = services.home.groupActions
            let shows = invocation.origin == .user
            // task-owner: the action run; a capturing caller (socket, CLI) awaits it through the registry.
            registry.track(result: Task { @MainActor in
                switch await actions.create(named: members, title: title, replies: replies) {
                case .created(let id):
                    if shows { services.home.pendingSelection = id }
                    return .success(["conversation": .string(id.rawValue)])
                case .refused(let outcome):
                    let reason = outcome.message ?? ""
                    registry.refuse(reason)
                    return .failure(ActionWorkFailure(refusal: outcome == .unknownConversation ? .notFound : .unavailable, reason: reason))
                }
            })
        })
        registry.bind("home.setChiefReplies", invoke: { invocation in
            guard let id = conversation(invocation, services) else { return }
            guard let policy = invocation["replies"]?.stringValue.flatMap(ChiefReplyPolicy.init(argument:)) else {
                return registry.refuse(HomeGroupOutcome.refused("").message ?? "")
            }
            runGroup(services) { await $0.setChiefReplies(policy, id) }
        })
        HomeListActions(page: { shownPage(services) }, source: { pinSource(services) }, conversation: { conversation($0, services) },
                        notReady: RefusalStrings.homeNotReady, pinTitles: (PinStrings.pinConversation, PinStrings.unpinConversation)).bind(into: registry)
        // A chat's own colours: arguments set them (`cmux chat colors`, MCP); a person's run with none opens the panel.
        registry.bindEffect("home.chatColors", requires: nil, effect: { invocation in
            guard let id = conversation(invocation, services) else { return .done }
            let values = ["sent", "sentText", "received", "receivedText"].reduce(into: [String: String]()) { $0[$1] = invocation[$1]?.stringValue }
            guard try !services.home.chatColors.apply(values, reset: invocation["reset"]?.boolValue == true, to: id.rawValue) else { return .done }
            let name = services.home.homeStore.rows.first { $0.id == id }?.title ?? ""
            services.home.chatColorsPanel.show(conversation: id.rawValue, name: name, over: services.windows.active?.window)
            return .done
        })
        registry.bind("home.sendMessage", invoke: { invocation in
            guard let id = conversation(invocation, services) else { return }
            let text = invocation["text"]?.stringValue ?? ""
            runGroup(services) { await $0.send(text, to: id) }
        })
    }

    /// The conversation an action names (`conversation`), else the one Home shows; refused when neither.
    private static func conversation(_ invocation: ActionInvocation, _ services: AppServices) -> ConversationID? {
        if let text = invocation["conversation"]?.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            return ConversationID(text)
        }
        guard let shown = shownPage(services)?.shown else {
            services.registry.refuse(RefusalStrings.homeNotReady)
            return nil
        }
        return shown
    }

    /// The native Home page of the active window (classic) or of the docked Home, without showing it.
    static func shownPage(_ services: AppServices) -> TopHomePageView? {
        if services.home.dock.isClassic { return services.windows.active?.topPages.views[.home] as? TopHomePageView }
        return HomeDockTab.view(services)?.messages
    }

    /// The pins a Home pin change goes to: the shown page's sidebar (its list redraws), else a
    /// source over the same stores (pins live with the owner or in this account's store, not in a page).
    private static func pinSource(_ services: AppServices) -> HomeSidebarSource {
        shownPage(services)?.sidebar ?? services.home.makeSidebarSource()
    }

    /// Runs a group action; the caller that waits (socket, CLI) gets its refusal as the failure.
    private static func runGroup(_ services: AppServices, _ body: @escaping @MainActor (HomeGroupActions) async -> HomeGroupOutcome) {
        let actions = services.home.groupActions
        let work = ActionWork {
            let outcome = await body(actions)
            guard !outcome.succeeded else { return nil }
            let refusal: ActionWorkRefusal = outcome == .unknownConversation ? .notFound : .unavailable
            return ActionWorkFailure(refusal: refusal, reason: outcome.message ?? "")
        }
        services.registry.track(work)
    }
}
