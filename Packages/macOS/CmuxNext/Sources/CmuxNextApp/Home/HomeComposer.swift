import CmuxHomeCore
import CmuxNextHome
import Foundation

/// New Message and Invite as Home ops (home-messaging.md 4.1 and 16.10),
/// through the one store (`HomeStore.perform`, so each op has its key and
/// the cloud owner decides): one person is `dm.open`, several people are
/// `conversation.create`, addresses become DM invites (`dm.open` with the
/// address; a verified team domain is the owner's call). The owner's
/// refusals become outcomes the sheet can say.
@MainActor
struct HomeComposer {
    var perform: @MainActor (HomeOp) async throws -> HomeOpResult

    func start(_ recipients: [HomeRecipient], title: String) async -> HomeComposeOutcome {
        var people: [HomeContact] = []
        var addresses: [ContactAddress] = []
        for recipient in recipients {
            switch recipient {
            case .contact(let contact): people.append(contact)
            case .address(let address): addresses.append(address)
            }
        }
        guard !recipients.isEmpty else { return .refused("") }
        if !people.isEmpty, !addresses.isEmpty { return .mixedRecipients }
        let op: HomeOp
        if let person = people.first, people.count == 1 {
            op = .openDirect(peer: person.id)
        } else if !people.isEmpty {
            op = .createGroup(title: title, participants: people.map(\.id))
        } else {
            op = .startConversation(contacts: addresses, firstMessage: [])
        }
        let naming = recipients.count == 1 ? recipients[0].label : recipients.map(\.label).joined(separator: ", ")
        do {
            let result = try await perform(op)
            guard let conversation = result.conversation else { return .refused("") }
            return .opened(conversation)
        } catch {
            return Self.outcome(for: error, naming: naming)
        }
    }

    /// Invite to cmux-next: a DM invite to the address (the owner sends the
    /// email; on staging only to its allow list).
    func invite(_ address: ContactAddress) async -> HomeComposeOutcome {
        guard address.isEmail else { return .invalidAddress(address.description) }
        do {
            let result = try await perform(.invite(contact: address))
            return .invited(result.conversation)
        } catch {
            return Self.outcome(for: error, naming: address.description)
        }
    }

    /// The owner's refusal as the sheet says it.
    static func outcome(for error: any Error, naming: String) -> HomeComposeOutcome {
        guard let rejection = error as? HomeRejection else { return .refused(String(describing: error)) }
        switch rejection {
        case .rateLimited: return .rateLimited
        case .ownerUnreachable: return .offline
        case .notAuthorized: return .notReachable(naming)
        case .indeterminate: return .refused("")
        case .invalid(let reason):
            switch reason {
            case "not_reachable": return .notReachable(naming)
            case "home.rate_limited": return .rateLimited
            case "invalid_invite": return .invalidAddress(naming)
            default: return .refused(HomeConversationStrings.inviteRefusal(reason))
            }
        }
    }
}
