import CmuxHomeCore
import CmuxNextActions
import CmuxNextHome
import Foundation

/// The Home page's conversation actions (HomeActionCatalog): one path for
/// the page's "+" menu, the File menu, the palette, `cmux action run` and
/// the CLI verbs. Without arguments New Message, Invite and New Chief open
/// their sheet on the Home page; with arguments they run headless and the
/// caller waits for the owner's answer (`ActionRegistry.track`).
extension AppActions {
    static func bindHomeConversations(_ services: AppServices) {
        let registry = services.registry
        registry.bind("home.newMessage", invoke: { invocation in
            guard let to = invocation["to"]?.stringValue?.trimmingCharacters(in: .whitespaces), !to.isEmpty else {
                homePage(services)?.presentNewMessage()
                return
            }
            // Comma-separated: several people make a group (`title` names it).
            let recipients = to.split(separator: ",").map { recipient(for: $0.trimmingCharacters(in: .whitespaces), services: services) }
            let title = invocation["title"]?.stringValue ?? ""
            runHome(services) { await services.home.startConversation(recipients, title: title) }
        })
        registry.bind("home.invite", invoke: { invocation in
            guard let text = invocation["email"]?.stringValue, !text.isEmpty else {
                homePage(services)?.presentInvite(prefill: "")
                return
            }
            guard let address = ContactAddress.parse(text), address.isEmail else {
                registry.refuse(HomeComposeOutcome.invalidAddress(text).message ?? text)
                return
            }
            runHome(services) { await services.home.invite(address) }
        })
        registry.bind("home.newChief", invoke: { invocation in
            guard let name = invocation["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                homePage(services)?.presentNewChief()
                return
            }
            runHome(services) { await services.home.createChief(named: name) }
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
            registry.track(work)
        })
        // Cmd-Shift-[ / ] on Home: the previous or next conversation in the list; stops at the ends.
        for (id, offset) in [("home.previousConversation", -1), ("home.nextConversation", 1)] as [(ActionID, Int)] {
            registry.bind(id) {
                guard let page = homePage(services) else { return }
                guard let next = page.sidebar.model().neighbor(of: page.shown, offset: offset) else { return }
                page.show(next)
            }
        }
        registry.bind("home.openConversation", invoke: { invocation in
            guard let id = invocation["conversation"]?.stringValue, !id.isEmpty else {
                registry.refuse(RefusalStrings.homeNotReady)
                return
            }
            guard let page = homePage(services) else { return }
            page.show(ConversationID(id))
        })
    }

    /// The Home page of the active window, shown (nil, refused, when no
    /// window may show it). A run that may not change the view (a socket
    /// run without focus) is told so, not that Home is not ready.
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
