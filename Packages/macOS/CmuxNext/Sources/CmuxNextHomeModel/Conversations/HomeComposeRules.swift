public import CmuxHomeCore
import Foundation

/// The send path's rules (cmux-tui/crates/cmux-home-rules `compose.*`) as the Swift types call
/// them: the values the ops read (``Contact``, ``Row``), and one call that never throws into a
/// view. Where a send goes, the attachment check, group outcomes, the team invite's words and the
/// directory's failure words live in Rust (tests/compose_*.rs); the Swift types keep their APIs
/// and ask through a value of this. The To: draft, `@` mention runs and routing's name match stay in Swift
/// until the Rust folds text as Foundation does.
package nonisolated struct HomeComposeRules: Sendable {
    package init() {}

    /// Runs `compose.NAME` on `input`. A failure (the linked library without the op, a reply that
    /// does not decode) stops a debug build and returns `fallback` in a release one.
    package func call<In: Encodable, Out: Decodable>(_ name: String, _ input: In, fallback: @autoclosure () -> Out) -> Out {
        do {
            return try HomeRules.call("compose.\(name)", input)
        } catch {
            assertionFailure(String(describing: error))
            return fallback()
        }
    }

    /// ``HomeContact`` (`compose::types::Contact`).
    package nonisolated struct Contact: Encodable, Sendable {
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
        var source: String?
        var members: [Contact]?

        package init(rows: [InboxRow], me: ParticipantID?, chief: ConversationID?, chiefNames: [ConversationID: String],
                     source: String? = nil, members: [HomeContact]? = nil) {
            self.rows = rows.orderedForInbox().map(Row.init)
            self.me = me?.rawValue
            self.chief = chief?.rawValue
            self.chiefNames = Dictionary(uniqueKeysWithValues: chiefNames.map { ($0.key.rawValue, $0.value) })
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
