package import Foundation

/// One feed item as the daemon's feed client returns it (`feed.item.get`, `feed.items.list`, an
/// entry of `feed.view.read`; plans/cmux-next/feed-page.md 2): the item's wire JSON (FeedDO shape,
/// snake_case, times in Unix ms) decoded only as far as the native glue reads it. It is not a
/// model: the daemon owns the items, and the page draws them.
package nonisolated struct FeedDaemonItem: Decodable, Sendable, Equatable {
    package struct Context: Decodable, Sendable, Equatable {
        package var workspace: String?
        package var tab: String?
        package var terminal: String?
        package var browserTab: String?
        package var acpSession: String?
        package var url: String?
        enum CodingKeys: String, CodingKey {
            case workspace, tab, terminal, url
            case browserTab = "browser_tab", acpSession = "acp_session"
        }
    }

    package struct Poster: Decodable, Sendable, Equatable {
        package var kind: String?
        package var label: String?
        /// The poster's scope (`system:cloud:<team>` for a Cloud owner).
        package var scope: String?
    }

    /// The parts of a prompt the glue reads: a sign-in's page and tab, an approve's hold.
    package struct Prompt: Decodable, Sendable, Equatable {
        package struct Action: Decodable, Sendable, Equatable {
            package struct Input: Decodable, Sendable, Equatable {
                package struct Approval: Decodable, Sendable, Equatable {
                    package var request: String?
                    package var team: String?
                }
                package var approval: Approval?
            }
            package var input: Input?

            enum CodingKeys: String, CodingKey { case input }

            /// An approve's `input` is any JSON value (a tool's own input): only an object with an
            /// `approval` is read, anything else is absent.
            package init(from decoder: any Decoder) throws {
                input = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Input.self, forKey: .input)
            }
        }
        package var url: String?
        package var browserTab: String?
        package var action: Action?
        enum CodingKeys: String, CodingKey {
            case url, action
            case browserTab = "browser_tab"
        }

        /// A kind's prompt can be any JSON: the fields the glue reads are read where they have
        /// their type, and a prompt of another shape is an empty one, never a failed item.
        package init(from decoder: any Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
            url = try? container.decodeIfPresent(String.self, forKey: .url)
            browserTab = try? container.decodeIfPresent(String.self, forKey: .browserTab)
            action = try? container.decodeIfPresent(Action.self, forKey: .action)
        }
    }

    /// The owner's answer record: who answered on which device, and the value.
    package struct Answer: Decodable, Sendable, Equatable {
        package struct Value: Decodable, Sendable, Equatable {
            package struct Proof: Decodable, Sendable, Equatable {
                package var install: String?
                package var ts: Int64?
                package var sig: String?
            }
            package var decision: String?
            package var scope: String?
            package var reason: String?
            package var confirmed: Bool?
            package var proof: Proof?

            enum CodingKeys: String, CodingKey { case decision, scope, reason, confirmed, proof }

            /// A custom kind's answer is any object: a field of another type reads as absent, never
            /// as a failed decode of the whole item.
            package init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                decision = try? container.decodeIfPresent(String.self, forKey: .decision)
                scope = try? container.decodeIfPresent(String.self, forKey: .scope)
                reason = try? container.decodeIfPresent(String.self, forKey: .reason)
                confirmed = try? container.decodeIfPresent(Bool.self, forKey: .confirmed)
                proof = try? container.decodeIfPresent(Proof.self, forKey: .proof)
            }
        }
        package var value: Value?
        package var by: String?
        package var device: String?

        enum CodingKeys: String, CodingKey { case value, by, device }

        package init(from decoder: any Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
            value = try? container.decodeIfPresent(Value.self, forKey: .value) // a custom kind's value may be no object
            by = try? container.decodeIfPresent(String.self, forKey: .by)
            device = try? container.decodeIfPresent(String.self, forKey: .device)
        }
    }

    /// The daemon's GitHub details of a GitHub item (pull request or issue).
    package struct GitHub: Decodable, Sendable, Equatable {
        package var title: String?
        package var repo: String?
        package var number: Int?
        package var url: String?
        package var branch: String?
    }

    package var id: String
    /// `cloud` or `local:<install>`.
    package var home: String?
    /// `request` or `notice` (absent: by `kind`).
    package var type: String?
    package var kind: String?
    package var title: String?
    package var body: String?
    package var dedupeKey: String?
    package var context: Context?
    package var poster: Poster?
    package var prompt: Prompt?
    package var state: String?
    package var answer: Answer?
    package var archivedAt: Double?
    package var createdAt: Double?
    package var github: GitHub?
    package var githubActions: [String]?

    enum CodingKeys: String, CodingKey {
        case id, home, type, kind, title, body, context, poster, prompt, state, answer, github
        case dedupeKey = "dedupe_key", archivedAt = "archived_at", createdAt = "created_at", githubActions = "github_actions"
    }

    package var isNotice: Bool { type.map { $0 == "notice" } ?? (kind ?? "notice" == "notice") }
    package var isOpen: Bool { (state ?? "open") == "open" }
    package var isClosed: Bool { !isOpen }
    package var isOpenRequest: Bool { !isNotice && isOpen }
    package var isArchived: Bool { archivedAt != nil }
    package var createdDate: Date { Date(timeIntervalSince1970: (createdAt ?? 0) / 1000) }
    package var url: URL? { (context?.url ?? github?.url).flatMap(URL.init(string:)) }

    /// The Cloud approval hold (`apr_…` and its team) this item asks the person to answer: an approve item
    /// posted by its team's Cloud owner (`system:cloud:<team>`), as the backend's `approvalOf` reads it.
    package var cloudHold: (request: String, team: String)? {
        guard (home ?? "cloud") == "cloud", kind == "approve", let hold = prompt?.action?.input?.approval,
              let request = hold.request, let team = hold.team, !request.isEmpty, !team.isEmpty,
              poster?.kind == "integration", poster?.scope == "system:cloud:\(team)" else { return nil }
        return (request, team)
    }

    /// An approve item's answer (`decision`, `scope`, the phone's `proof`); nil for any other kind or
    /// without an answer. An unknown decision reads as deny, as the owner's own reader does.
    package var approveDecision: FeedApproveDecision? {
        guard kind == "approve", let value = answer?.value else { return nil }
        let proof = value.proof.flatMap { proof -> FeedApproveDecision.Proof? in
            guard let install = proof.install, let ts = proof.ts, let sig = proof.sig else { return nil }
            return FeedApproveDecision.Proof(install: install, timestampMs: ts, signature: sig)
        }
        return FeedApproveDecision(FeedApproveDecision.Outcome(rawValue: value.decision ?? "") ?? .deny,
                                   scope: value.scope.flatMap(FeedApproveDecision.Scope.init(rawValue:)),
                                   reason: value.reason, proof: proof)
    }

    /// A confirm item's answer (`confirmed`); nil for any other kind or without an answer.
    package var confirmAnswer: Bool? {
        guard kind == "confirm", let value = answer?.value else { return nil }
        return value.confirmed ?? false
    }
}

/// The value of an `approve` answer (feed.md 3.4): what the bridge checks before it answers an agent.
package nonisolated struct FeedApproveDecision: Sendable, Equatable {
    package enum Outcome: String, Sendable, Equatable { case allow, deny }
    package enum Scope: String, Sendable, Equatable { case once, session, always }
    package var outcome: Outcome
    package var scope: Scope?
    package var reason: String?
    /// The phone's presence-key proof (`answer.proof`, cx-aocz).
    package var proof: Proof?

    package init(_ outcome: Outcome, scope: Scope? = nil, reason: String? = nil, proof: Proof? = nil) {
        self.outcome = outcome
        self.scope = scope
        self.reason = reason
        self.proof = proof
    }

    /// The signing install, when it signed (ms) and the base64url raw P-256 signature; the owner
    /// checked only their shape.
    package struct Proof: Sendable, Equatable {
        package var install: String
        package var timestampMs: Int64
        package var signature: String
    }
}
