public import CmuxHomeCore
public import CmuxNextHome
import Foundation

/// The one path for managing a person-to-person DM or group (plans/cmux-next/home-dm-group-chats):
/// the group info sheet, the Home row menu and the `home.*` group actions (palette, CLI, MCP) all
/// call it. Each op opens the conversation for its duration (`HomeStore.open`, paired with
/// `close`), so a Cloud conversation's subscription is live when the op goes out; one already
/// open stays open.
///
/// ```swift
/// let actions = HomeGroupActions(store: store, muting: sidebar, contacts: { home.contacts() })
/// let outcome = await actions.rename(id, to: "Lisbon trip")
/// ```
@MainActor
public struct HomeGroupActions: Sendable {
    private let store: HomeStore
    private let muting: any HomeConversationMuting
    private let contacts: @MainActor @Sendable () -> [HomeContact]

    /// - Parameters:
    ///   - store: The app's HomeStore (the single writer).
    ///   - muting: Where Hide Alerts goes (the app's ``HomeSidebarSource``).
    ///   - contacts: The people the user can add (team members and connections).
    public init(store: HomeStore, muting: any HomeConversationMuting, contacts: @escaping @MainActor @Sendable () -> [HomeContact]) {
        self.store = store
        self.muting = muting
        self.contacts = contacts
    }

    // MARK: Reading

    /// What the group info sheet shows for `id`; nil when the list has no such conversation.
    public func info(_ id: ConversationID) -> HomeGroupInfo? {
        guard let row = store.rows.first(where: { $0.id == id }) else { return nil }
        let me = store.me?.id
        let members = row.summary.participants.map { HomeGroupMember($0, me: me) }
        let ordered = members.filter(\.isMe) + members.filter { !$0.isMe }
        let title = row.summary.title.isHomeInternalID ? "" : row.summary.title
        return HomeGroupInfo(conversation: id, isGroup: row.kind == .group, title: title, displayTitle: row.title,
                             members: ordered, canMute: muting.canMute(id), muted: muting.isMuted(id) || row.summary.muted,
                             memberCount: row.summary.memberCount, chiefReplies: Self.chiefReplies(of: row),
                             canAddPeople: Self.isMyCloudChief(row, me: me) || (row.kind == .group && row.summary.declaredKind != .chief),
                             canRename: row.kind == .group && row.summary.declaredKind != .chief)
    }

    /// `id` is my Cloud Chief's conversation (people are added and removed there, though it is no group).
    private func sharesMyChief(_ id: ConversationID) -> Bool {
        store.rows.first { $0.id == id }.map { Self.isMyCloudChief($0, me: store.me?.id) } ?? false
    }

    /// My Cloud Chief's own conversation: I share it with teammates there (cmux#25569); the owner
    /// takes only people of a shared team, never another agent.
    static func isMyCloudChief(_ row: InboxRow, me: ParticipantID?) -> Bool {
        guard row.summary.owner == .cloud, let me else { return false }
        return row.summary.isMyChiefLine(me: me)
    }

    /// The Chiefs Reply setting the group info shows: nil for a DM, a group without a Chief, or a
    /// local group (its owner has no setting); else the owner's, ``ChiefReplyPolicy/default`` when it names none.
    static func chiefReplies(of row: InboxRow) -> ChiefReplyPolicy? {
        // Someone else's Chief conversation shared with me: only its owner sets anything there.
        guard row.kind == .group, row.summary.declaredKind != .chief, row.summary.owner == .cloud,
              row.summary.participants.contains(where: \.isChief) else { return nil }
        return row.summary.chiefReplies ?? .default
    }

    /// The people the user can add to `id`: contacts not already in it.
    public func addable(to id: ConversationID) -> [HomeContact] {
        let row = store.rows.first { $0.id == id }
        let present = Set(row?.summary.participants.map(\.id) ?? [])
        let peopleOnly = row?.kind == .chief
        return contacts().filter { !present.contains($0.id) && !(peopleOnly && $0.source == .agent) }
    }

    /// The names in a comma-separated list (`--people "Aziz, leo@example.com"`), trimmed, without empties.
    public static func names(in list: String) -> [String] {
        list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The member of `id` that `text` names: by id, else by name (any case).
    public func member(_ text: String, in id: ConversationID) -> ParticipantID? {
        let participants = store.rows.first { $0.id == id }?.summary.participants ?? []
        return Self.match(text, in: participants.map { ($0.id, $0.visibleName) })
    }

    /// The contact `text` names: by id, else by name (any case), else a person or Chief of another
    /// conversation of mine with that name.
    public func contact(_ text: String) -> ParticipantID? {
        if let id = Self.match(text, in: contacts().map { ($0.id, $0.name) }) { return id }
        let me = store.me?.id
        let known = store.rows.flatMap(\.summary.participants).filter {
            $0.id != me && ($0.kind == .human || $0.isChief) && $0.membership == .active
        }
        return Self.match(text, in: known.map { ($0.id, $0.visibleName) })
    }

    private static func match(_ text: String, in people: [(ParticipantID, String)]) -> ParticipantID? {
        if let byID = people.first(where: { $0.0.rawValue == text }) { return byID.0 }
        return people.first { !$0.1.isEmpty && $0.1.localizedCaseInsensitiveCompare(text) == .orderedSame }?.0
    }

    // MARK: Changes

    /// Renames the group `id` (an empty title goes back to the members' names).
    public func rename(_ id: ConversationID, to title: String) async -> HomeGroupOutcome {
        await run(on: id, naming: "") { .renameConversation(conversation: id, title: title.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Adds `people` to the group `id`.
    public func add(_ people: [ParticipantID], to id: ConversationID, naming: String = "") async -> HomeGroupOutcome {
        guard !people.isEmpty else { return .noPeople }
        return await run(on: id, naming: naming, requiresGroup: !sharesMyChief(id)) { .addParticipants(conversation: id, participants: people) }
    }

    /// Adds the people a comma-separated list names (contacts by name or id; an email of a cmux
    /// user the owner resolves). The first name nobody matches is refused before anything is sent.
    public func add(named list: String, to id: ConversationID) async -> HomeGroupOutcome {
        let names = Self.names(in: list)
        guard !names.isEmpty else { return .noPeople }
        guard summary(id) != nil else { return .unknownConversation }
        var people: [ParticipantID] = []
        for name in names {
            if let person = contact(name) {
                people.append(person)
            } else if let address = ContactAddress.parse(name), address.isEmail {
                guard case .member(let person)? = try? await store.resolve(address) else { return .notReachable(name) }
                people.append(person.id)
            } else {
                return .unknownPerson(name)
            }
        }
        return await add(people, to: id, naming: names.joined(separator: ", "))
    }

    /// Removes `person` from the group `id`; removing me is leaving (``leave(_:)``).
    public func remove(_ person: ParticipantID, from id: ConversationID) async -> HomeGroupOutcome {
        if person == store.me?.id { return await leave(id) }
        let name = summary(id)?.participants.first { $0.id == person }?.visibleName ?? person.rawValue
        return await run(on: id, naming: name, removing: true, requiresGroup: !sharesMyChief(id)) { .removeParticipant(conversation: id, participant: person) }
    }

    /// Removes the member `text` names (id or name).
    public func remove(named text: String, from id: ConversationID) async -> HomeGroupOutcome {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .noPeople }
        guard summary(id) != nil else { return .unknownConversation }
        guard let person = member(name, in: id) else { return .notAMember(name) }
        return await remove(person, from: id)
    }

    /// I leave the group `id`; it goes from my list once the owner says so.
    public func leave(_ id: ConversationID) async -> HomeGroupOutcome {
        guard let me = store.me?.id else { return .offline }
        let outcome = await run(on: id, naming: "") { .removeParticipant(conversation: id, participant: me) }
        return outcome == .done ? .left : outcome
    }

    /// Starts a group of the people and Chiefs a comma-separated list names (`cmux chat create
    /// --members "Chief, Unii, aziz@manaflow.com"`), as New Message's first send does, then sets
    /// its Chiefs Reply setting when `replies` asks for one. The first name nobody matches is
    /// refused before anything is sent.
    public func create(named list: String, title: String, replies: ChiefReplyPolicy? = nil) async -> HomeGroupCreation {
        let names = Self.names(in: list)
        guard !names.isEmpty else { return .refused(.noPeople) }
        var people: [ParticipantID] = []
        for name in names {
            if let person = contact(name) {
                if person != store.me?.id, !people.contains(person) { people.append(person) }
            } else if let address = ContactAddress.parse(name), address.isEmail {
                guard case .member(let person)? = try? await store.resolve(address) else { return .refused(.notReachable(name)) }
                if !people.contains(person.id) { people.append(person.id) }
            } else {
                return .refused(.unknownPerson(name))
            }
        }
        guard !people.isEmpty else { return .refused(.noPeople) }
        let op = HomeOp.createGroup(title: title.trimmingCharacters(in: .whitespacesAndNewlines), participants: people)
        let id: ConversationID
        do {
            guard let made = try await store.perform(op).conversation else { return .refused(.refused("")) }
            id = made
        } catch let rejection as HomeRejection {
            return .refused(HomeGroupOutcome(rejection: rejection, naming: names.joined(separator: ", ")))
        } catch {
            return .refused(.refused(""))
        }
        if let replies, replies != .default {
            let outcome = await setChiefReplies(replies, id, waiting: true)
            guard outcome.succeeded else { return .refused(outcome) }
        }
        return .created(id)
    }

    /// Sets when the Chiefs of the group `id` answer (`cmux chat replies`, the group info's
    /// Chiefs Reply row). `waiting`: a group just made may not be listed yet; the op goes anyway.
    public func setChiefReplies(_ policy: ChiefReplyPolicy, _ id: ConversationID, waiting: Bool = false) async -> HomeGroupOutcome {
        if waiting, summary(id) == nil {
            do {
                _ = try await store.perform(.setChiefReplies(conversation: id, policy: policy))
                return .done
            } catch let rejection as HomeRejection {
                return HomeGroupOutcome(rejection: rejection, naming: "")
            } catch {
                return .refused("")
            }
        }
        return await run(on: id, naming: "") { .setChiefReplies(conversation: id, policy: policy) }
    }

    /// Hide Alerts (`on`) or Show Alerts for `id`.
    public func setMuted(_ on: Bool, _ id: ConversationID) -> HomeGroupOutcome {
        guard summary(id) != nil else { return .unknownConversation }
        guard muting.canMute(id) else { return .cannotMute }
        muting.setMuted(on, id)
        return .done
    }

    /// Sends `text` to `id` as me. Offline, it waits for the owner (`queued`).
    public func send(_ text: String, to id: ConversationID) async -> HomeGroupOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyText }
        guard summary(id) != nil else { return .unknownConversation }
        let outcome = await run(on: id, naming: "", requiresGroup: false) { .sendMessage(conversation: id, parts: [.text(trimmed)]) }
        return outcome == .offline ? .queued : outcome
    }

    // MARK: Running one op

    private func summary(_ id: ConversationID) -> ConversationSummary? {
        store.rows.first { $0.id == id }?.summary
    }

    /// Opens `id` for the op (a Cloud op needs its subscription live), runs it, closes again.
    private func run(on id: ConversationID, naming: String, removing: Bool = false, requiresGroup: Bool = true,
                     _ op: () -> HomeOp) async -> HomeGroupOutcome {
        guard let row = store.rows.first(where: { $0.id == id }) else { return .unknownConversation }
        if requiresGroup, row.kind != .group { return .notAGroup }
        let op = op()
        await store.open(id)
        defer { store.close(id) }
        do {
            _ = try await store.perform(op)
            return .done
        } catch let rejection as HomeRejection {
            return HomeGroupOutcome(rejection: rejection, naming: naming, removing: removing)
        } catch {
            return .refused("")
        }
    }
}
