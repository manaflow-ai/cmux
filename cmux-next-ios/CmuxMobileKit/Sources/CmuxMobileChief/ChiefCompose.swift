#if os(iOS)
import CmuxConversationCore
import CmuxConversationUI
import CmuxMobileAgentChat
import CmuxMobileModel
import Foundation
import UIKit

/// A conversation Home opens on its own stack: Chief (from select mode's
/// Forward), Chief with the composer focused (Home's compose button), or an
/// agent's chat.
public enum HomeConversationRoute: Hashable, Sendable {
    /// A Chief conversation: the Cloud Chief or the Mac Chief.
    case chief(ChiefRoute.Place)
    case chiefComposing(ChiefRoute.Place)
    case agent(AgentChatDestination)
    /// A conversation of the Mac's Home list other than the Mac Chief's.
    case mac(MacConversationRoute)

    /// The navigation value to push for Chief, nil for an agent.
    public var chiefRoute: ChiefRoute? {
        switch self {
        case let .chief(place): ChiefRoute(place: place)
        case let .chiefComposing(place): ChiefRoute(focusesComposer: true, place: place)
        case .agent, .mac: nil
        }
    }
}

/// One recipient New Message can address: Chief, or an agent tab of an
/// active workspace ("Claude · cmux").
struct ChiefRecipient: Sendable, Hashable {
    let contact: ConversationContact
    let route: HomeConversationRoute
}

/// New Message's recipients: Chief first, then every agent conversation of
/// the active workspaces, as Messages lists contacts. Typed text that names
/// no recipient is not a valid address (red token), as in Messages.
final class ChiefDirectory: ConversationDirectory, @unchecked Sendable {
    static let chiefContactID = ChiefIdentity.standard.chiefID
    let recipients: [ChiefRecipient]

    init(recipients: [ChiefRecipient]) {
        self.recipients = recipients
    }

    @MainActor
    static func recipients(store: AppStore, identity: ChiefIdentity, place: ChiefRoute.Place) -> [ChiefRecipient] {
        var all = [ChiefRecipient(
            contact: ConversationContact(
                id: chiefContactID, name: identity.title, initials: identity.avatar, colorHex: "#636366",
                handles: [ConversationContactHandle(value: String(localized: "Runs your agents"), label: "Chief", service: .iMessage)]
            ),
            route: .chief(place)
        )]
        for workspace in store.activeWorkspaces {
            for tab in workspace.tabs where tab.kind == .agent {
                let name = "\(tab.title) · \(workspace.title)"
                all.append(ChiefRecipient(
                    contact: ConversationContact(
                        id: "tab:\(tab.id)", name: name,
                        initials: tab.harness == "codex" ? "CX" : String(tab.title.prefix(2)).uppercased(),
                        colorHex: "#636366",
                        handles: [ConversationContactHandle(value: workspace.title, label: tab.harness?.capitalized ?? "Agent", service: .iMessage)]
                    ),
                    route: .agent(AgentChatDestination(workspaceID: workspace.id, tabID: tab.id))
                ))
            }
        }
        return all
    }

    func recipient(id: String) -> ChiefRecipient? {
        recipients.first { $0.contact.id == id }
    }

    private func matches(_ contact: ConversationContact, _ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return contact.name.localizedCaseInsensitiveContains(query)
            || contact.handles.contains { $0.value.localizedCaseInsensitiveContains(query) }
    }

    func searchContacts(_ query: String, limit: Int, excluding: [String]) async throws -> [ConversationContact] {
        Array(recipients.map(\.contact).filter { !excluding.contains($0.id) && matches($0, query) }.prefix(limit))
    }

    func lookupHandles(_ handles: [String]) async throws -> [ConversationHandleLookup] {
        handles.map { handle in
            let found = recipients.first { $0.contact.name.caseInsensitiveCompare(handle) == .orderedSame }
                ?? recipients.first { $0.contact.name.localizedCaseInsensitiveContains(handle) }
            return ConversationHandleLookup(handle: handle, service: found == nil ? nil : .iMessage, contact: found?.contact)
        }
    }

    func createConversation(_ refs: [ConversationRecipientRef]) async throws -> ConversationCreation {
        let picked = refs.compactMap { ref -> ChiefRecipient? in
            switch ref {
            case let .participant(id): return recipient(id: id)
            case let .handle(handle): return recipients.first { $0.contact.name.caseInsensitiveCompare(handle) == .orderedSame }
            }
        }
        guard !picked.isEmpty, picked.count == refs.count else {
            throw ConversationBackendError(code: -32005, message: "not a valid address")
        }
        // One agent opens its own chat; Chief, or several recipients at once,
        // open the Chief conversation (Chief routes the message to them).
        let id = picked.count == 1 ? picked[0].contact.id : Self.chiefContactID
        let participants = picked.map {
            ConversationParticipant(id: $0.contact.id, name: $0.contact.name, initials: $0.contact.initials, colorHex: $0.contact.colorHex, isMe: false)
        }
        return ConversationCreation(
            info: ConversationInfo(id: id, title: picked.map(\.contact.name).joined(separator: ", "), kind: picked.count > 1 ? .group : .direct, participants: participants),
            created: false, service: .iMessage
        )
    }
}

/// Select mode's Forward in the Chief conversation: Messages' New Message
/// sheet (CmuxConversation's `ConversationComposeViewController`) over a
/// `ChiefDirectory`. The first send opens the conversation in Home's stack
/// and sends there:
/// - Chief alone: the Chief conversation.
/// - One agent: that agent's chat, with the message as its prompt.
/// - Several recipients: the Chief conversation, the message addressed to
///   them by name, so Chief routes it.
@MainActor
public final class ChiefComposer {
    let store: AppStore
    let session: ChiefSession
    let open: (HomeConversationRoute) -> Void

    public init(store: AppStore, session: ChiefSession = .shared, open: @escaping (HomeConversationRoute) -> Void) {
        self.store = store
        self.session = session
        self.open = open
    }

    /// The Chief this composer writes to, as a route place.
    var place: ChiefRoute.Place { session === ChiefSession.cloud ? .cloud : .mac }

    @discardableResult
    public func present() -> Bool {
        guard let presenter = Self.topController() else { return false }
        let directory = ChiefDirectory(recipients: ChiefDirectory.recipients(store: store, identity: session.identity, place: place))
        let compose = ConversationComposeViewController(directory: directory)
        // The sheet holds this composer for as long as it is up: Home makes a
        // new composer on each redraw, so a weak one was often gone by Send,
        // which then closed the sheet and sent nothing.
        compose.onOpenConversation = { [weak compose] creation, message in
            compose?.presentingViewController?.dismiss(animated: true)
            self.route(creation, message: message, directory: directory)
        }
        #if DEBUG
        ChiefDemoHook.shared.compose = compose
        #endif
        presenter.present(compose.makeSheet(), animated: true)
        pending = compose
        return true
    }

    /// Forward from select mode: New Message prefilled with the draft.
    public func present(forwarding draft: ConversationForwardDraft) {
        guard present() else { return }
        pending?.setDraft(forwarding: draft)
    }

    private weak var pending: ConversationComposeViewController?

    func route(_ creation: ConversationCreation, message: ConversationComposeMessage, directory: ChiefDirectory) {
        if creation.info.id != ChiefDirectory.chiefContactID,
           let recipient = directory.recipient(id: creation.info.id),
           case let .agent(destination) = recipient.route,
           let workspace = store.workspace(id: destination.workspaceID),
           let tab = workspace.tabs.first(where: { $0.id == destination.tabID }) {
            let mac = store.teams.flatMap(\.macs).first { $0.id == workspace.macID }?.name ?? "Mac"
            let chat = AgentSessionDirectory.shared.store(workspace: workspace, tab: tab, macName: mac)
            open(.agent(destination))
            if !message.text.isEmpty { chat.send(prompt: message.text) }
            return
        }
        var routed = message
        let others = creation.info.participants.filter { $0.id != ChiefDirectory.chiefContactID }
        if !others.isEmpty, !message.text.isEmpty {
            routed.text = "To \(others.map(\.name).joined(separator: ", ")): \(message.text)"
        }
        // Forwarded from inside this Chief's own conversation: send there,
        // instead of pushing a second copy of the same screen over it.
        if session.conversationID == nil || ChiefSession.conversationOnScreen != session.conversationID {
            open(.chief(place))
        }
        session.send(routed)
    }

    /// The controller to present the sheet from: the frontmost one.
    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}
#endif
