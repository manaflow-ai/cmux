#if os(iOS)
import CmuxConversationCore
import CmuxMobileAgentChat
import CmuxMobileModel
import Foundation

/// Who New Message can address from Home, as the Mac's New Message lists them
/// (`HomeRecipientField`, `HomeNewMessageDraft`): the Chiefs, main first, each
/// tagged where it runs ("Chief · Main · Cloud", "Chief · Studio"), then the
/// team; typed text also finds the agent chats of the active workspaces and
/// takes an email address or phone number.
struct HomeRecipientEntry: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// The open Cloud Chief or the Mac Chief (their sessions are Home's).
        case chief(ChiefRoute.Place)
        /// Another of the account's Cloud Chiefs: its main conversation.
        case cloudChief(agentID: String, conversation: String)
        /// A Chief of the Mac's Home list other than the Mac Chief.
        case macChief(MacConversationRoute)
        /// A team member (`team.members.list`), by Cloud participant id.
        case teammate(participant: String)
        /// An agent tab of an active workspace (found by typing only).
        case agentTab(AgentChatDestination)
        /// A typed email address or phone number.
        case address(String, isEmail: Bool)

        /// A Chief or a teammate takes part in a Cloud conversation (a group).
        var cloudParticipant: (id: String, agent: Bool)? {
            switch self {
            case let .cloudChief(agent, _): (agent, true)
            case let .teammate(participant): (participant, false)
            case .chief, .macChief, .agentTab, .address: nil
            }
        }

        var isChief: Bool {
            switch self {
            case .chief, .cloudChief, .macChief: true
            case .teammate, .agentTab, .address: false
            }
        }
    }

    var contact: ConversationContact
    var kind: Kind
    /// The newest message, for "Active 2 hours ago" when two rows read alike.
    var activity: Date?
}

/// The Home data New Message reads, gathered on the main actor when it opens
/// (and again when the team or the Chiefs arrive).
struct HomeRecipientSnapshot: Sendable {
    var chiefs: [HomeRecipientEntry]
    var team: [HomeRecipientEntry]
    var agentTabs: [HomeRecipientEntry]
    /// The active team's name, for "Invite … to <team>" (nil: no team to invite to, or no way to).
    var teamName: String?
    var canCreateChief: Bool
    var canInvite: Bool
    /// The open Cloud Chief's agent id: it joins a group as itself.
    var openCloudChiefAgent: String?
    /// The team could not be read: the list shows no Team section (as the Mac shows no team).
    var teamUnread = false
}

/// New Message's directory and list for Home: ``HomeRecipientSnapshot``'s
/// people in the Mac's sections and order, its typed-text rules, and the
/// first send's Cloud calls (`dm.open`, `conversation.create`).
@MainActor
final class HomeNewMessageDirectory: ConversationDirectory, ConversationComposeListing {
    static let newChiefAction = ConversationComposeAction(id: "newChief", title: String(localized: "New Chief…"), systemImage: "plus")
    static let inviteAction = ConversationComposeAction(id: "invite", title: String(localized: "Invite to cmux…"), systemImage: "envelope")
    static let inviteToTeamPrefix = "inviteToTeam:"

    var snapshot: HomeRecipientSnapshot
    /// Cloud calls with this account's token (nil: signed out or no Cloud in this build).
    let cloud: AccountCloud?
    /// This account's Cloud participant id (`user_<id>`).
    let me: String?
    /// The entries the last search or lookup answered, by contact id, so a
    /// typed address that became a token is still known at the first send.
    private var known: [String: HomeRecipientEntry] = [:]
    /// Runs before a first send to one Chief opens its conversation (the presenter opens the
    /// Mac channel); a throw is the refusal under To:.
    var prepare: (@MainActor (HomeRecipientEntry) async throws -> Void)?
    /// One idempotency key per recipient set: Send again after a failure (a lost reply, a refused
    /// invite) replays the same group instead of making a second one (the Mac keys from the intent).
    private var keys: [[String]: String] = [:]
    /// The Cloud write (tests replace it); defaults to ``AccountCloud/mutate(_:params:key:team:)``.
    var mutate: (@MainActor (_ op: String, _ params: [String: any Sendable], _ key: String) async throws -> Data)?

    init(snapshot: HomeRecipientSnapshot, cloud: AccountCloud?, me: String?) {
        self.snapshot = snapshot
        self.cloud = cloud
        self.me = me
        remember(snapshot)
    }

    func update(_ next: HomeRecipientSnapshot) {
        snapshot = next
        remember(next)
    }

    private func remember(_ snapshot: HomeRecipientSnapshot) {
        for entry in snapshot.chiefs + snapshot.team + snapshot.agentTabs { known[entry.contact.id] = entry }
    }

    func entry(id: String) -> HomeRecipientEntry? { known[id] }

    // MARK: The list under To:

    /// Before anything is typed (the Mac's `idleRows`): the Chiefs under
    /// "Chiefs" with New Chief after them, then everyone else under "Team"
    /// (Invite when the team has nobody else).
    func idleRows(excluding: [String]) -> [ConversationComposeRow] {
        let chosen = Set(excluding)
        let chiefs = snapshot.chiefs.filter { !chosen.contains($0.contact.id) }
        let team = snapshot.team.filter { !chosen.contains($0.contact.id) }
        var rows: [ConversationComposeRow] = []
        if !chiefs.isEmpty || snapshot.canCreateChief {
            rows.append(.header(String(localized: "Chiefs")))
            rows += chiefs.map { .contact($0.contact) }
            if snapshot.canCreateChief { rows.append(.action(Self.newChiefAction)) }
        }
        if !snapshot.teamUnread, !team.isEmpty || snapshot.canInvite {
            rows.append(.header(String(localized: "Team")))
            rows += team.isEmpty ? [.action(Self.inviteAction)] : team.map { .contact($0.contact) }
        }
        return rows
    }

    /// While text is typed: the matches, and after a typed email address an
    /// "Invite … to <team>" row (an address in To: gets a DM invite; this row
    /// invites to the team), as on the Mac.
    func typedRows(matches: [ConversationContact], query: String) -> [ConversationComposeRow] {
        var rows = matches.map(ConversationComposeRow.contact)
        if let team = snapshot.teamName,
           let index = matches.firstIndex(where: { if case .address(_, true)? = known[$0.id]?.kind { true } else { false } }),
           case let .address(address, _)? = known[matches[index].id]?.kind {
            rows.insert(.action(ConversationComposeAction(
                id: Self.inviteToTeamPrefix + address,
                title: String(format: String(localized: "Invite %1$@ to %2$@"), address, team),
                systemImage: "person.2.badge.plus"
            )), at: index + 1)
        }
        return rows
    }

    // MARK: ConversationDirectory

    /// The Mac's `HomeNewMessageDraft.suggestions`: a typed address first,
    /// then names with a word starting with the text, then names containing
    /// it (people already chosen left out). A blank query lists everyone (the
    /// + picker).
    func searchContacts(_ query: String, limit: Int, excluding: [String]) async throws -> [ConversationContact] {
        let chosen = Set(excluding)
        let everyone = (snapshot.chiefs + snapshot.team + snapshot.agentTabs).filter { !chosen.contains($0.contact.id) }
        let text = query.trimmingCharacters(in: Self.separators)
        guard !text.isEmpty else { return everyone.map(\.contact) }
        var result: [HomeRecipientEntry] = []
        if let address = Self.address(text) {
            let entry = Self.addressEntry(address.value, isEmail: address.isEmail)
            if !chosen.contains(entry.contact.id) {
                known[entry.contact.id] = entry
                result.append(entry)
            }
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let wordStart = everyone.filter { entry in
            entry.contact.name.split(whereSeparator: \.isWhitespace).contains { $0.range(of: text, options: options.union(.anchored)) != nil }
        }
        let inside = everyone.filter { entry in
            entry.contact.name.range(of: text, options: options) != nil && !wordStart.contains(entry)
        }
        result += wordStart + inside
        return Array(result.prefix(min(limit, 8)).map(\.contact))
    }

    /// Return in To: (the Mac's `HomeNewMessageDraft.resolve`): an address,
    /// else the person the text names exactly, else the only one whose name
    /// starts with it; otherwise a red token.
    func lookupHandles(_ handles: [String]) async throws -> [ConversationHandleLookup] {
        handles.map { handle in
            guard let entry = resolve(handle) else { return ConversationHandleLookup(handle: handle, service: nil, contact: nil) }
            known[entry.contact.id] = entry
            return ConversationHandleLookup(handle: handle, service: .iMessage, contact: entry.contact)
        }
    }

    func resolve(_ text: String) -> HomeRecipientEntry? {
        let text = text.trimmingCharacters(in: Self.separators)
        guard !text.isEmpty else { return nil }
        if let address = Self.address(text) { return Self.addressEntry(address.value, isEmail: address.isEmail) }
        let everyone = snapshot.chiefs + snapshot.team + snapshot.agentTabs
        if let exact = everyone.first(where: { $0.contact.name.compare(text, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return exact
        }
        let starts = everyone.filter { $0.contact.name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil }
        return starts.count == 1 ? starts[0] : nil
    }

    /// The first send (the Mac's `HomeComposer.start`): one Chief or agent
    /// chat opens its own conversation; one teammate or address is `dm.open`;
    /// several people are a Cloud group (`conversation.create`, each address
    /// invited into it). Mac Chiefs and agent chats live on the Mac, so they
    /// cannot join a Cloud group: the Cloud would refuse them.
    func createConversation(_ refs: [ConversationRecipientRef]) async throws -> ConversationCreation {
        let picked = refs.compactMap { ref -> HomeRecipientEntry? in
            switch ref {
            case let .participant(id): known[id]
            case let .handle(handle): resolve(handle)
            }
        }
        guard !picked.isEmpty, picked.count == refs.count else { throw Self.refusal(String(localized: "Add someone in To: first.")) }
        let participants = picked.map {
            ConversationParticipant(id: $0.contact.id, name: $0.contact.name, initials: $0.contact.initials, colorHex: $0.contact.colorHex, isMe: false)
        }
        let title = picked.map(\.contact.name).joined(separator: ", ")
        if picked.count == 1 {
            let entry = picked[0]
            switch entry.kind {
            case .chief, .cloudChief, .macChief, .agentTab:
                try await prepare?(entry)
                return ConversationCreation(info: ConversationInfo(id: entry.contact.id, title: title, kind: .direct, participants: participants),
                                            created: false, service: .iMessage)
            case let .teammate(participant):
                let id = try await open("dm.open", ["peer": participant], key: key(for: refs))
                return Self.cloudCreation(id, title: title, participants: participants, group: false)
            case let .address(address, isEmail):
                let id = try await open("dm.open", ["peer": [isEmail ? "email" : "phone": address]], key: key(for: refs))
                return Self.cloudCreation(id, title: title, participants: participants, group: false)
            }
        }
        if picked.contains(where: { if case .chief(.mac) = $0.kind { true } else { false } })
            || picked.contains(where: { if case .macChief = $0.kind { true } else if case .agentTab = $0.kind { true } else { false } }) {
            throw Self.refusal(String(localized: "A Chief or agent chat on your Mac can't join a group. Start the group with Cloud Chiefs and teammates."))
        }
        var records: [[String: any Sendable]] = []
        if let me { records.append(["id": me, "kind": "human", "display_name": ""]) }
        var addresses: [(String, Bool)] = []
        for entry in picked {
            switch entry.kind {
            case .chief(.cloud):
                if let id = snapshot.openCloudChiefAgent {
                    records.append(["id": id, "kind": "agent", "agent_class": "mux", "display_name": entry.contact.name])
                }
            case let .address(address, isEmail): addresses.append((address, isEmail))
            default:
                guard let participant = entry.kind.cloudParticipant else { continue }
                var record: [String: any Sendable] = ["id": participant.id, "kind": participant.agent ? "agent" : "human",
                                                      "display_name": entry.contact.name]
                if participant.agent { record["agent_class"] = "mux" }
                records.append(record)
            }
        }
        let key = key(for: refs)
        let id = try await open("conversation.create", ["participants": records], key: key)
        for (index, address) in addresses.enumerated() {
            // The group's members see the invitee masked, as the Mac sends it (`WireHomeSource.masked`).
            _ = try await call("invite.create", ["conversation": id, "address": [address.1 ? "email" : "phone": address.0],
                                                 "display_name": Self.masked(address.0, isEmail: address.1)],
                               key: "\(key):invite:\(index)")
        }
        return Self.cloudCreation(id, title: title, participants: participants, group: true)
    }

    // MARK: Cloud calls

    /// The key for this recipient set, the same on every Send of this sheet.
    private func key(for refs: [ConversationRecipientRef]) -> String {
        let set = refs.map { "\($0)" }.sorted()
        if let key = keys[set] { return key }
        let key = UUID().uuidString.lowercased()
        keys[set] = key
        return key
    }

    /// An address as the group shows an invitee (the Mac's `WireHomeSource.masked`): `a***@host`,
    /// or `+1 *** *** 1234`; anything else `***`.
    static func masked(_ address: String, isEmail: Bool) -> String {
        if isEmail {
            let pieces = address.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return "***" }
            return "\(pieces[0].prefix(1))***@\(pieces[1])"
        }
        let digits = address.dropFirst()
        guard address.hasPrefix("+"), (11...15).contains(digits.count), digits.allSatisfy({ ("0"..."9").contains($0) }) else { return "***" }
        return "+\(digits.dropLast(10)) *** *** \(address.suffix(4))"
    }

    private func open(_ op: String, _ params: [String: any Sendable], key: String) async throws -> String {
        let data = try await call(op, params, key: key)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conversation = object["conversation"] as? [String: Any], let id = conversation["id"] as? String, !id.isEmpty else {
            throw Self.refusal(String(localized: "cmux Cloud answered something the phone can't read."))
        }
        return id
    }

    private func call(_ op: String, _ params: [String: any Sendable], key: String) async throws -> Data {
        if let mutate { return try await mutate(op, params, key) }
        #if DEBUG
        if cloud == nil, DeveloperOptions.mockContentEnabled {
            // Demo and UI tests: no Cloud service; a stable made-up conversation per call.
            return try JSONSerialization.data(withJSONObject: ["conversation": ["id": "conv_demo_\(op)_\(abs(key.hashValue) % 10_000)"]])
        }
        #endif
        guard let cloud else { throw Self.refusal(String(localized: "Sign in to message people from your iPhone.")) }
        do {
            return try await cloud.mutate(op, params: params, key: key)
        } catch let failure as AccountCloud.Failure {
            throw Self.refusal(Self.describe(failure))
        }
    }

    /// The owner's refusal as New Message says it (the Mac's `HomeComposer.outcome`).
    static func describe(_ failure: AccountCloud.Failure) -> String {
        switch failure.code {
        case "not_reachable", "not_authorized": String(localized: "You can't message them yet. They may need to join your team first.")
        case "home.rate_limited", "rate_limited": String(localized: "Too many new conversations. Try again in a minute.")
        case "invalid_invite": String(localized: "That isn't a valid email address or phone number.")
        default: failure.description
        }
    }

    static func refusal(_ message: String) -> ConversationBackendError {
        ConversationBackendError(code: -32000, message: message)
    }

    private static func cloudCreation(_ id: String, title: String, participants: [ConversationParticipant],
                                      group: Bool) -> ConversationCreation {
        ConversationCreation(info: ConversationInfo(id: cloudConversationPrefix + id, title: title, kind: group ? .group : .direct,
                                                    participants: participants),
                             created: true, service: .iMessage)
    }

    /// A creation's id for a Cloud conversation the first send made.
    static let cloudConversationPrefix = "cloud:"

    // MARK: Addresses

    static let separators = CharacterSet(charactersIn: ",;").union(.whitespacesAndNewlines)

    /// An email address (one @, a dot after it) or a phone number (7 to 15
    /// digits, with + ( ) - . and spaces), as the Mac's `ContactAddress.parse`.
    static func address(_ text: String) -> (value: String, isEmail: Bool)? {
        let text = text.trimmingCharacters(in: separators)
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        if parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
           !text.contains(where: \.isWhitespace) {
            return (text.lowercased(), true)
        }
        let allowed = CharacterSet(charactersIn: "+()-. 0123456789")
        let digits = text.filter(\.isNumber)
        if text.unicodeScalars.allSatisfy(allowed.contains), (7...15).contains(digits.count) {
            return ((text.hasPrefix("+") ? "+" : "") + digits, false)
        }
        return nil
    }

    static func addressEntry(_ address: String, isEmail: Bool) -> HomeRecipientEntry {
        HomeRecipientEntry(
            contact: ConversationContact(id: "address:\(address)", name: address, initials: isEmail ? "@" : "#", colorHex: "#8E8E93",
                                         handles: [ConversationContactHandle(value: address, label: "", service: isEmail ? .iMessage : .sms)],
                                         detail: isEmail ? String(localized: "Email") : String(localized: "Phone"), tintsWithService: true),
            kind: .address(address, isEmail: isEmail)
        )
    }

    // MARK: Lines under the names

    /// Each row's line (the Mac's `HomeRecipientSuggestionsView.lines`): where
    /// it comes from and a Chief's tag; a row that reads like another one gets
    /// when it was last active, and still alike, a number ("2").
    static func withLines(_ entries: [HomeRecipientEntry], now: Date = Date()) -> [HomeRecipientEntry] {
        var result = entries
        func collisions() -> [[Int]] {
            Dictionary(grouping: result.indices, by: { "\(result[$0].contact.name)\u{0}\(result[$0].contact.detail ?? "")" })
                .values.filter { $0.count > 1 }.map { $0.sorted() }
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        for indices in collisions() {
            for index in indices {
                let line: String = result[index].activity.map {
                    String(format: String(localized: "Active %@"), formatter.localizedString(for: min($0, now), relativeTo: now))
                } ?? String(localized: "No messages yet")
                result[index].contact.detail = (result[index].contact.detail ?? "") + " \u{00B7} " + line
            }
        }
        for indices in collisions() {
            for (number, index) in indices.enumerated() where number > 0 {
                result[index].contact.detail = (result[index].contact.detail ?? "") + " \u{00B7} \(number + 1)"
            }
        }
        return result
    }

    /// The members of a `team.members.list` value, without this account, by name (the Mac's
    /// `HomeDirectory.members`).
    static func teammates(from data: Data, excluding me: String?) -> [HomeRecipientEntry] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let list = object?["members"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        return list.compactMap { member -> HomeRecipientEntry? in
            guard let user = member["user"] as? String, !user.isEmpty else { return nil }
            let id = participantID(user)
            guard id != me, seen.insert(id).inserted else { return nil }
            let name = (member["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? user
            return teammate(id: id, name: name)
        }
        .sorted { $0.contact.name.localizedStandardCompare($1.contact.name) == .orderedAscending }
    }

    static func teammate(id: String, name: String) -> HomeRecipientEntry {
        HomeRecipientEntry(
            contact: ConversationContact(id: "team:\(id)", name: name, initials: homeInitials(name), colorHex: "#8E8E93",
                                         handles: [cmuxHandle], detail: String(localized: "Team")),
            kind: .teammate(participant: id)
        )
    }

    /// Everyone Home lists is reached in cmux: a blue token, as Messages draws an iMessage recipient
    /// (a contact with no iMessage handle would draw green, SMS).
    static let cmuxHandle = ConversationContactHandle(value: "cmux", label: "", service: .iMessage)

    /// The Cloud's participant id for a Stack user id (`user_<id>`).
    static func participantID(_ user: String) -> String {
        user.hasPrefix("user_") ? user : "user_" + user
    }
}
#endif
