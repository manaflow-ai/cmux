public import CmuxHomeCore
public import CmuxNextHome
import Foundation

/// New Message and Invite as Home ops (home-messaging.md 4.1 and 16.10),
/// through the one store (`HomeStore.perform`, so each op has its key and
/// the cloud owner decides): one person is `dm.open`, several people are
/// `conversation.create`, addresses become DM invites (`dm.open` with the
/// address; a verified team domain is the owner's call), and people with
/// addresses are one `conversation.create` that invites each address. The owner's
/// refusals become outcomes the sheet can say.
@MainActor
public struct HomeComposer {
    var perform: @MainActor (HomeOp) async throws -> HomeOpResult
    /// Text for an error that is no owner refusal (the app's refusal wording).
    var describe: @MainActor (any Error) -> String

    public init(perform: @escaping @MainActor (HomeOp) async throws -> HomeOpResult,
                describe: @escaping @MainActor (any Error) -> String) {
        self.perform = perform
        self.describe = describe
    }

    /// Starts a DM or group with `recipients`. `firstMessage` rides with an
    /// address-only start (`conversation.create` by contact carries it); for
    /// people the caller sends it into the opened conversation.
    public func start(_ recipients: [HomeRecipient], title: String, firstMessage: [MessagePart] = []) async -> HomeComposeOutcome {
        var people: [HomeContact] = []
        var addresses: [ContactAddress] = []
        for recipient in recipients {
            switch recipient {
            case .contact(let contact): people.append(contact)
            case .address(let address): addresses.append(address)
            }
        }
        guard !recipients.isEmpty else { return .refused("") }
        let op: HomeOp
        if !people.isEmpty, !addresses.isEmpty {
            // People and addresses: one group with the people, each address invited into it.
            op = .createGroup(title: title, participants: people.map(\.id), invites: addresses)
        } else if let person = people.first, people.count == 1 {
            op = .openDirect(peer: person.id)
        } else if !people.isEmpty {
            op = .createGroup(title: title, participants: people.map(\.id))
        } else {
            op = .startConversation(contacts: addresses, firstMessage: firstMessage)
        }
        let naming = recipients.count == 1 ? recipients[0].label : recipients.map(\.label).joined(separator: ", ")
        do {
            let result = try await perform(op)
            guard let conversation = result.conversation else { return .refused("") }
            return .opened(conversation)
        } catch {
            return outcome(for: error, naming: naming)
        }
    }

    /// Invite to cmux-next: a DM invite to the address (the owner sends the
    /// email; on staging only to its allow list).
    public func invite(_ address: ContactAddress) async -> HomeComposeOutcome {
        guard address.isEmail else { return .invalidAddress(address.description) }
        do {
            let result = try await perform(.invite(contact: address))
            return .invited(result.conversation)
        } catch {
            return outcome(for: error, naming: address.description)
        }
    }

    /// The owner's refusal as the sheet says it.
    func outcome(for error: any Error, naming: String) -> HomeComposeOutcome {
        // Sent, but no answer came (the store resends it, or gave up): a state, not a reason to show.
        if error is HomeSendState { return .cloudUnreachable }
        guard let rejection = error as? HomeRejection else { return .refused(describe(error)) }
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
            default: return .refusal(code: reason)
            }
        }
    }
}
