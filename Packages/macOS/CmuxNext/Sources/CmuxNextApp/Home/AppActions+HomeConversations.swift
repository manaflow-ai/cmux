import CmuxHomeCore
import CmuxNextActions
import CmuxNextCloud
import CmuxNextHome
import CmuxNextHomeEngine
import Foundation

/// The Home page's conversation actions (HomeActionCatalog): one path for
/// the page's "+" menu, the File menu, the palette, `cmux action run` and
/// the CLI verbs. Without arguments New Message opens the New Message page
/// (a draft row and a To: field, as in Messages) and Invite and New Chief
/// open their sheet on the Home page (the docked Home: a route of its page,
/// AppActions+HomeDockRoutes); with arguments they run headless and the
/// caller waits for the owner's answer (`ActionRegistry.track`).
extension AppActions {
    static func bindHomeConversations(_ services: AppServices) {
        let registry = services.registry
        registry.bind("home.newMessage", invoke: { invocation in
            guard let to = invocation["to"]?.stringValue?.trimmingCharacters(in: .whitespaces), !to.isEmpty else {
                guard services.home.dock.isClassic else { return openDockRoute(HomeDockRoute.newMessage, services) { $0.presentNewMessage() } }
                homePage(services)?.presentNewMessage()
                return
            }
            // Comma-separated: several people make a group (`title` names it).
            let recipients = to.split(separator: ",").map { recipient(for: $0.trimmingCharacters(in: .whitespaces), services: services) }
            let title = invocation["title"]?.stringValue ?? ""
            runHome(services) { await services.home.startConversation(recipients, title: title) }
        })
        // Close New Message (the draft row's x, Escape in To:, palette, CLI, MCP) acts only on an open draft.
        registry.bindEffect("home.closeNewMessage", unavailable: {
            newMessagePage(services) == nil ? RefusalStrings.noNewMessage : nil
        }, effect: { _ in
            guard let page = newMessagePage(services) else { return .refused(RefusalStrings.noNewMessage) }
            page.closeNewMessage(); return .done
        })
        registry.bind("home.invite", invoke: { invocation in
            guard let text = invocation["email"]?.stringValue, !text.isEmpty else {
                guard services.home.dock.isClassic else { return openDockRoute(HomeDockRoute.newInvite, services) { $0.presentInvite(prefill: "") } }
                homePage(services)?.presentInvite(prefill: "")
                return
            }
            guard let address = ContactAddress.parse(text), address.isEmail else {
                registry.refuse(HomeComposeOutcome.invalidAddress(text).message ?? text)
                return
            }
            runHome(services) { await services.home.invite(address) }
        })
        // Invite to Team: its dialog shows over the active window now (HomeTeamInviteRun).
        let cloud = services.cloud
        registry.bindEffect("home.inviteToTeam", unavailable: {
            !cloud.isSignedIn ? CloudStrings.signInFirst : cloud.auth.activeTeam.team == nil ? CloudStrings.noTeams : nil
        }, effect: { invocation in
            guard let team = cloud.auth.activeTeam.team else { return .refused(CloudStrings.noTeams) }
            guard let window = services.windows.active?.window else { return .refused(RefusalStrings.homeNotReady) }
            return HomeTeamInviteRun(auth: cloud.auth, teamID: team.id, teamName: team.displayName).effect(invocation, over: window)
        })
        registry.bind("home.newChief", invoke: { invocation in
            guard let name = invocation["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                guard services.home.dock.isClassic else { return openChannelsRoute(HomeDockRoute.newChief, services) { $0.presentNewChief() } }
                homePage(services)?.presentNewChief()
                return
            }
            let backendName = invocation["harness"]?.stringValue
                ?? invocation["engine"]?.stringValue
                ?? ChiefBackend.claude.id
            guard let backend = ChiefBackend(id: backendName) else {
                return registry.refuse("unknown Chief harness: \(backendName)")
            }
            // A headless caller (CLI, MCP, or an agent acting for the person)
            // needs the created Chief's durable id, not an empty `created` list.
            registry.track(result: Task { @MainActor in
                switch await services.home.createChiefForAction(named: name, backend: backend) {
                case .success(let chief):
                    return .success([
                        "id": .string(chief.id),
                        "name": .string(chief.name),
                        "conversation": .string(chief.mainConversation ?? ""),
                    ])
                case .failure(let outcome):
                    return .failure(ActionWorkFailure(refusal: .unavailable, reason: outcome.message ?? ""))
                }
            })
        })
        registry.bind("home.archiveChief", invoke: { invocation in
            guard let chief = invocation["chief"]?.stringValue, !chief.isEmpty else {
                registry.refuse(HomeStrings.archiveFailed)
                return
            }
            let work = ActionWork {
                guard let reason = await services.home.archiveChief(chief) else { return nil }
                return ActionWorkFailure(refusal: .unavailable, reason: reason)
            }
            registry.trackOrRefuse(work)
        })
        registry.bind("home.deleteChief", invoke: { invocation in
            guard let chief = invocation["chief"]?.stringValue, !chief.isEmpty else {
                registry.refuse(HomeStrings.deleteFailed)
                return
            }
            let work = ActionWork {
                guard let reason = await services.home.deleteChief(chief) else { return nil }
                return ActionWorkFailure(refusal: .unavailable, reason: reason)
            }
            registry.trackOrRefuse(work)
        })
        // Ctrl-Tab / Ctrl-Shift-Tab and Cmd-Shift-] / [ on Home: the next or previous conversation in
        // the list, wrapping as a pane's tabs do; opening it gives its message box the keyboard.
        for (id, offset) in [("home.previousConversation", -1), ("home.nextConversation", 1)] as [(ActionID, Int)] {
            registry.bind(id) {
                let step: @MainActor (TopHomePageView) -> Void = { page in
                    guard let next = page.sidebar.model().neighbor(of: page.shown, offset: offset, wrapping: true) else { return }
                    page.open(next)
                }
                // The docked Home steps its Messages list, or asks the Channels page to move through
                // its own list (`home.moveConversation`, the page's Option-Up/Down).
                guard services.home.dock.isClassic else {
                    return withDock(services) { dock in
                        if dock.mode == .channels, let channels = dock.channels {
                            // task-owner: one page call; ends with its answer (a second at most)
                            Task { @MainActor in
                                if await !HomeDockTab.moveConversation(channels, by: offset) {
                                    registry.refuse(MiscHandlerStrings.channelsCannotStep, quiet: true)
                                }
                            }
                            return
                        }
                        guard let page = dock.messages else { return }
                        step(page)
                    }
                }
                guard let page = homePage(services) else { return }
                step(page)
            }
        }
        // Ctrl-1…9 on Home: the nth conversation in the list, 9 the last (as Select Tab 1…9).
        registry.bind("home.selectConversationByNumber", invoke: { invocation in
            guard let number = invocation["index"]?.intValue else { return registry.refuse(RefusalStrings.indexRequired) }
            let pick: @MainActor (TopHomePageView) -> Void = { page in
                guard let id = page.sidebar.model().conversation(number: number) else { return }
                page.open(id)
            }
            guard services.home.dock.isClassic else {
                return withDock(services) { dock in
                    // The Channels page keeps its own list; it has no numbered pick.
                    guard dock.mode != .channels, let page = dock.messages else {
                        return registry.refuse(MiscHandlerStrings.channelsCannotStep, quiet: true)
                    }
                    pick(page)
                }
            }
            guard let page = homePage(services) else { return }
            pick(page)
        })
        registry.bind("home.switchView", invoke: { switchHomeView(services, $0) })
        registry.bind("home.openConversation", invoke: { invocation in
            guard let id = invocation["conversation"]?.stringValue, !id.isEmpty else {
                registry.refuse(RefusalStrings.homeNotReady)
                return
            }
            // The docked Home: its shown view opens the conversation (Channels: its hash route) and the dock has the keyboard.
            guard services.home.dock.isClassic else {
                return withDock(services) { dock in
                    dock.open(HomeDockView.Selection(conversation: id))
                    dock.focusPrimaryInput()
                }
            }
            guard let page = homePage(services) else { return }
            page.open(ConversationID(id))
        })
    }

    /// The Home page of the active window, shown (nil, refused, when no
    /// window may show it). A run that may not change the view (a socket
    /// run without focus) is told so, not that Home is not ready.
    /// The active window's Home page (classic, else the docked Home's) holding a New Message draft.
    static func newMessagePage(_ services: AppServices) -> TopHomePageView? {
        [services.windows.active?.topPages.views[.home] as? TopHomePageView, HomeDockTab.view(services)?.messages].lazy.compactMap { $0 }.first { $0.newMessage != nil }
    }

    static func homePage(_ services: AppServices) -> TopHomePageView? {
        guard ActionRunScope.viewChangeAllowed() else {
            services.registry.refuse(RefusalStrings.homeNeedsFocus)
            return nil
        }
        guard TopPages.show(.home, services: services) != nil,
              let page = services.windows.active?.topPages.views[.home] as? TopHomePageView else {
            services.registry.refuse(RefusalStrings.homeNotReady)
            return nil
        }
        return page
    }

    /// A typed recipient: an email address, else a contact by id or name.
    static func recipient(for text: String, services: AppServices) -> HomeRecipient {
        if let address = ContactAddress.parse(text), address.isEmail { return .address(address) }
        let contacts = services.home.contacts()
        if let contact = contacts.first(where: { $0.id.rawValue == text || $0.name.localizedCaseInsensitiveCompare(text) == .orderedSame }) {
            return .contact(contact)
        }
        return .contact(HomeContact(id: ParticipantID(text), name: text, source: .team))
    }

    /// Runs a headless Home action; the caller (socket, CLI) gets the
    /// owner's refusal as the action's failure. A conversation it opened
    /// is selected on the Home page once listed.
    private static func runHome(_ services: AppServices, _ body: @escaping @MainActor () async -> HomeComposeOutcome) {
        let work = ActionWork {
            let outcome = await body()
            switch outcome {
            case .opened, .invited: return nil
            default: return ActionWorkFailure(refusal: .unavailable, reason: outcome.message ?? "")
            }
        }
        services.registry.track(work)
    }
}
