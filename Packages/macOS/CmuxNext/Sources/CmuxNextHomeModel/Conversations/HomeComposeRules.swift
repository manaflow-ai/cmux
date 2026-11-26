public import CmuxHomeCore
import Foundation

/// New Message's and the send path's rules (cmux-tui/crates/cmux-home-rules `compose.*`) as the
/// Swift types call them: the values each op reads and writes (``Contact``, ``Recipient``,
/// ``Draft``, ``Row``), and one call that never throws into a view. The To: field's tokens and
/// suggestions, where a send goes, `@` mention runs, the attachment check, group outcomes and the
/// team invite's words live in Rust (tests/compose_*.rs); the Swift types keep their APIs and ask
/// through here.
package nonisolated enum HomeComposeRules {
    /// Runs `compose.NAME` on `input`. A failure (the linked library without the op, a reply that
    /// does not decode) stops a debug build and returns `fallback` in a release one.
    package static func call<In: Encodable, Out: Decodable>(_ name: String, _ input: In, fallback: @autoclosure () -> Out) -> Out {
        do {
            return try HomeRules.call("compose.\(name)", input)
        } catch {
            assertionFailure(String(describing: error))
            return fallback()
        }
    }

    /// ``HomeContact`` (`compose::types::Contact`).
    package nonisolated struct Contact: Codable, Sendable {
        var id: String
        var name: String
        /// `team`, `connection` or `agent`.
        var source: String

        package init(_ contact: HomeContact) {
            id = contact.id.rawValue
            name = contact.name
            source = switch contact.source {
            case .team: "team"
            case .connection: "connection"
            case .agent: "agent"
            }
        }

        package var contact: HomeContact {
            let source: HomeContact.Source = switch self.source {
            case "agent": .agent
            case "connection": .connection
            default: .team
            }
            return HomeContact(id: ParticipantID(id), name: name, source: source)
        }
    }

    /// ``ContactAddress`` (`compose::text::Address`).
    package nonisolated struct Address: Codable, Sendable {
        /// `email` or `phone`.
        var kind: String
        var value: String

        package init(_ address: ContactAddress) {
            kind = address.isEmail ? "email" : "phone"
            value = address.description
        }

        package var address: ContactAddress { kind == "email" ? .email(value) : .phone(value) }
    }

    /// ``HomeRecipient`` (`compose::types::Recipient`, tagged by `kind`).
    package nonisolated struct Recipient: Codable, Sendable {
        var kind: String
        var contact: Contact?
        var address: Address?

        package init(_ recipient: HomeRecipient) {
            switch recipient {
            case .contact(let contact):
                kind = "contact"
                self.contact = Contact(contact)
            case .address(let address):
                kind = "address"
                self.address = Address(address)
            }
        }

        package var recipient: HomeRecipient? {
            if let contact { return .contact(contact.contact) }
            if let address { return .address(address.address) }
            return nil
        }
    }

    /// One To: token (`compose::types::Token`).
    package nonisolated struct Token: Codable, Sendable {
        package var text: String
        var recipient: Recipient?

        package init(text: String, recipient: HomeRecipient?) {
            self.text = text
            self.recipient = recipient.map(Recipient.init)
        }

        package var homeRecipient: HomeRecipient? { recipient?.recipient }
    }

    /// The To: field (`compose::types::Draft`).
    package nonisolated struct Draft: Codable, Sendable {
        package var tokens: [Token]
        package var query: String

        package init(tokens: [Token], query: String) {
            self.tokens = tokens
            self.query = query
        }
    }

    /// A draft op's reply: the draft after it, and whether it changed (`draft::Changed`).
    package nonisolated struct Changed: Decodable, Sendable {
        package var draft: Draft
        package var changed: Bool
    }

    /// `draft.state`'s reply.
    package nonisolated struct DraftState: Decodable, Sendable {
        package var recipients: [Recipient]
        package var hasInvalidTokens: Bool
        package var isEmpty: Bool
        package var isGroup: Bool
        package var sendBlocker: SendBlocker?

        package static let empty = DraftState(recipients: [], hasInvalidTokens: false, isEmpty: true, isGroup: false, sendBlocker: nil)

        package var homeRecipients: [HomeRecipient] { recipients.compactMap(\.recipient) }
    }

    /// Why the first send waits (`draft::SendBlocker`).
    package nonisolated struct SendBlocker: Decodable, Sendable {
        /// `unknownRecipient` (with `text`) or `needsRecipient`.
        package var kind: String
        package var text: String?
    }

    /// The draft ops' requests (`draft::*Request`).
    package nonisolated struct DraftRequest: Encodable, Sendable {
        var draft: Draft
        var recipient: Recipient?
        var contacts: [Contact]?
        var limit: Int?
        var index: Int?
        var rows: [Row]?
        var me: String?

        package init(draft: Draft, recipient: HomeRecipient? = nil, contacts: [HomeContact]? = nil, limit: Int? = nil,
                     index: Int? = nil, rows: [InboxRow]? = nil, me: ParticipantID? = nil) {
            self.draft = draft
            self.recipient = recipient.map(Recipient.init)
            self.contacts = contacts?.map(Contact.init)
            self.limit = limit
            self.index = index
            self.rows = rows?.map(Row.init)
            self.me = me?.rawValue
        }
    }

    /// `draft.resolve`'s request.
    package nonisolated struct ResolveRequest: Encodable, Sendable {
        var text: String
        var contacts: [Contact]

        package init(text: String, contacts: [HomeContact]) {
            self.text = text
            self.contacts = contacts.map(Contact.init)
        }
    }

    /// One inbox row as the compose rules read it (`compose::types::Row`).
    package nonisolated struct Row: Encodable, Sendable {
        var id: String
        var kind: String
        var title: String
        var summaryTitle: String
        var participants: [Participant]
        var owner: String
        var declaredKind: String?
        var chiefReplies: String?
        var memberCount: Int?
        var muted: Bool

        package init(_ row: InboxRow) {
            id = row.id.rawValue
            kind = row.kind.rawValue
            title = row.title
            summaryTitle = row.summary.title
            participants = row.summary.participants
            owner = row.summary.owner.rawValue
            declaredKind = row.summary.declaredKind?.rawValue
            chiefReplies = row.summary.chiefReplies?.rawValue
            memberCount = row.summary.memberCount
            muted = row.summary.muted
        }
    }

    /// The routing ops' inbox (`routing::Routing`): rows in inbox order.
    package nonisolated struct Routing: Encodable, Sendable {
        var rows: [Row]
        var me: String?
        var chief: String?
        var chiefNames: [String: String]
        var text: String?
        var source: String?
        var members: [Contact]?

        package init(rows: [InboxRow], me: ParticipantID?, chief: ConversationID?, chiefNames: [ConversationID: String],
                     text: String? = nil, source: String? = nil, members: [HomeContact]? = nil) {
            self.rows = rows.orderedForInbox().map(Row.init)
            self.me = me?.rawValue
            self.chief = chief?.rawValue
            self.chiefNames = Dictionary(uniqueKeysWithValues: chiefNames.map { ($0.key.rawValue, $0.value) })
            self.text = text
            self.source = source
            self.members = members?.map(Contact.init)
        }
    }

    /// An action field's choice (`routing::Choice`).
    package nonisolated struct Choice: Decodable, Sendable {
        package var value: String
        package var title: String
    }

    /// A group outcome (`group::Outcome`, tagged by `kind`).
    package nonisolated struct Outcome: Decodable, Sendable {
        package var kind: String
        package var name: String?
        package var reason: String?
    }
}
