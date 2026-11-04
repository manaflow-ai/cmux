public import CmuxNextDaemon
import Foundation
public import Observation
import CmuxNextWakeups

/// The Invite People sheet's state (design chat-multiplayer.md 2, "Invite people"): who is invited to
/// one chat, an account field and a role, the chat's invite link, and the work the sheet runs. Invite
/// and Remove are the same work `agent.share.invite` and `agent.share.uninvite` run
/// (``AgentShareActions/inviteWork(_:account:role:ttl:host:)``), so the sheet holds no share logic of
/// its own: it reads the chat's shares again after each change.
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
        /// Puts the invite link on the pasteboard.
        public var copy: @MainActor (_ text: String) -> Void

        public init(list: @escaping @MainActor () async throws -> [AgentSessionShare],
                    invite: @escaping @MainActor (_ account: String, _ role: String) async throws -> Void,
                    remove: @escaping @MainActor (_ account: String) async throws -> Void,
                    copy: @escaping @MainActor (_ text: String) -> Void = { _ in }) {
            self.list = list
            self.invite = invite
            self.remove = remove
            self.copy = copy
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
    /// The link invitees open (`<room>/i/<share>`, of the chat's invite share); nil until someone is
    /// invited, and without a room.
    public private(set) var inviteLink: String?
    /// Copy Invite Link just ran: it reads Copied for ``copiedFor``, then goes back.
    public private(set) var copied = false
    /// How long Copy Invite Link reads Copied.
    public var copiedFor: Duration = .milliseconds(1500)
    /// Why the last step did not finish; nil when it did.
    public private(set) var status: String?
    /// An Invite runs or waits its turn: Invite is off meanwhile.
    public private(set) var isWorking = false
    /// The accounts a Remove is running or waiting for.
    public private(set) var removing: Set<String> = []

    private let session: String
    private let work: Work
    /// The last Invite or Remove: the next one runs after it.
    @ObservationIgnored private var lastStep: Task<Void, Never>?
    /// Copied goes back to Copy Invite Link at this deadline; the next copy pushes it back.
    @ObservationIgnored private let copiedReset = DemandTimer(owner: "agentShare.copiedLink")

    public init(chat: String, session: String, role: String = "talk", work: Work) {
        self.chat = chat
        self.session = session
        self.role = role
        self.work = work
    }

    /// Invite is on once the field names someone and no Invite runs.
    public var canInvite: Bool { !isWorking && !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Reads who is invited and the invite link (when the sheet opens, and after every change).
    public func load() async {
        do {
            let shares = try await work.list()
            rows = AgentShareInvites.rows(of: session, in: shares)
            inviteLink = AgentShareInvites.inviteLink(of: session, in: shares)
        } catch {
            status = AgentShareStrings.failure(error).message
        }
    }

    /// Invites the field's account with ``role``; the field clears when the daemon took it, unless
    /// the person typed another account meanwhile.
    public func invite() async {
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canInvite else { return }
        let role = role
        isWorking = true
        defer { isWorking = false }
        await inTurn {
            do {
                try await self.work.invite(account, role)
                self.status = nil
                // Typing a next account while the invite ran keeps it.
                if self.account.trimmingCharacters(in: .whitespacesAndNewlines) == account { self.account = "" }
            } catch {
                self.status = AgentShareStrings.failure(error).message
            }
            await self.load()
        }
    }

    /// Removes `account`: it joins no more, and every device it joined from leaves.
    public func remove(_ account: String) async {
        guard !removing.contains(account) else { return }
        removing.insert(account)
        defer { removing.remove(account) }
        await inTurn {
            do {
                try await self.work.remove(account)
                self.status = nil
            } catch {
                self.status = AgentShareStrings.failure(error).message
            }
            await self.load()
        }
    }

    /// Puts the invite link on the pasteboard; Copy Invite Link reads Copied for ``copiedFor``.
    public func copyLink() {
        guard let inviteLink else { return }
        work.copy(inviteLink)
        copied = true
        copiedReset.schedule(after: copiedFor) { @MainActor [weak self] in
            self?.copied = false
        }
    }

    /// Runs `step` after every Invite and Remove pressed before it, so two steps for one account (an
    /// Invite, then a Remove) land in the order pressed.
    private func inTurn(_ step: @escaping @MainActor () async -> Void) async {
        let before = lastStep
        // task-owner: one Invite or Remove, after the one before it; ends with the step
        let mine = Task { @MainActor in
            await before?.value
            await step()
        }
        lastStep = mine
        await mine.value
    }
}
