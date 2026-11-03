import CmuxNextDaemon
import Foundation
import Observation

/// The Invite People sheet's state (design chat-multiplayer.md 2, "Invite people"): who is invited to
/// one chat, an account field and a role, and the work the sheet runs. Invite and Remove are the same
/// work `agent.share.invite` and `agent.share.uninvite` run (``AgentShareActions/inviteWork(_:account:role:ttl:host:)``),
/// so the sheet holds no share logic of its own: it reads the chat's shares again after each change.
@MainActor @Observable
public final class AgentShareInviteSheetModel {
    /// One invited account.
    public struct Row: Hashable, Identifiable, Sendable {
        /// Trimmed and lowercased by the daemon.
        public var account: String
        /// `view` or `talk`.
        public var role: String
        /// A device of the account is in the chat now.
        public var joined: Bool

        public var id: String { account }

        public init(account: String, role: String, joined: Bool) {
            self.account = account
            self.role = role
            self.joined = joined
        }
    }

    /// The daemon work behind the sheet.
    public struct Work {
        /// The chat's shares.
        public var list: @MainActor () async throws -> [AgentSessionShare]
        /// Invites an account with a role.
        public var invite: @MainActor (_ account: String, _ role: String) async throws -> Void
        /// Removes an invited account from every share of the chat.
        public var remove: @MainActor (_ account: String) async throws -> Void

        public init(list: @escaping @MainActor () async throws -> [AgentSessionShare],
                    invite: @escaping @MainActor (_ account: String, _ role: String) async throws -> Void,
                    remove: @escaping @MainActor (_ account: String) async throws -> Void) {
            self.list = list
            self.invite = invite
            self.remove = remove
        }
    }

    /// The chat's tab title.
    public let chat: String
    /// What the account field holds.
    public var account = ""
    /// The role the next invite gets: `talk` (the default) or `view`.
    public var role: String
    /// The invited accounts, oldest first.
    public private(set) var rows: [Row] = []
    /// Why the last step did not finish; nil when it did.
    public private(set) var status: String?
    /// A step runs: Invite and Remove wait for it.
    public private(set) var isWorking = false
    /// The accounts a Remove is running for.
    public private(set) var removing: Set<String> = []

    private let session: String
    private let work: Work

    public init(chat: String, session: String, role: String = "talk", work: Work) {
        self.chat = chat
        self.session = session
        self.role = role
        self.work = work
    }

    /// Invite is on once the field names someone and nothing else runs.
    public var canInvite: Bool { !isWorking && !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Reads who is invited (when the sheet opens, and after every change).
    public func load() async {
        do {
            rows = AgentShareInvites.rows(of: session, in: try await work.list())
        } catch {
            status = AgentShareStrings.failure(error).message
        }
    }

    /// Invites the field's account with ``role``; the field clears when the daemon took it.
    public func invite() async {
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canInvite else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await work.invite(account, role)
            status = nil
            self.account = ""
        } catch {
            status = AgentShareStrings.failure(error).message
        }
        await load()
    }

    /// Removes `account`: it joins no more, and every device it joined from leaves.
    public func remove(_ account: String) async {
        guard !removing.contains(account) else { return }
        removing.insert(account)
        defer { removing.remove(account) }
        do {
            try await work.remove(account)
            status = nil
        } catch {
            status = AgentShareStrings.failure(error).message
        }
        await load()
    }
}
