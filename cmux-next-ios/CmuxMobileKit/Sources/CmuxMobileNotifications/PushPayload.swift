import Foundation

/// What a push from a Mac is about (PROTOCOL.md "Push notifications (API 0.12.0)").
public enum PushKind: String, Codable, Sendable, CaseIterable {
    case question, permission, completed, failed, chief, terminal

    /// An ask the agent waits on.
    public var isAsk: Bool { self == .question || self == .permission }
}

/// One acpmux permission option (`options` of a permission push).
public struct PushOption: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case allowOnce = "allow_once"
        case allowAlways = "allow_always"
        case rejectOnce = "reject_once"
        case rejectAlways = "reject_always"
    }

    public var id: String
    public var label: String
    /// Nil for a kind this build does not know.
    public var kind: Kind?

    public init(id: String, label: String, kind: Kind?) {
        self.id = id
        self.label = label
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case id, label, kind }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0.flatMap(Kind.init(rawValue:)) }
    }

    public var isAllow: Bool { kind == .allowOnce || kind == .allowAlways }
    public var isReject: Bool { kind == .rejectOnce || kind == .rejectAlways }
}

/// One AskUserQuestion-style question (`questions` of a question push).
public struct PushQuestion: Codable, Sendable, Equatable {
    public struct Option: Codable, Sendable, Equatable {
        public var label: String
        public var description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public var question: String
    public var header: String?
    public var multiSelect: Bool
    public var allowsOther: Bool
    public var options: [Option]

    public init(question: String, header: String? = nil, multiSelect: Bool = false, allowsOther: Bool = false, options: [Option]) {
        self.question = question
        self.header = header
        self.multiSelect = multiSelect
        self.allowsOther = allowsOther
        self.options = options
    }

    enum CodingKeys: String, CodingKey { case question, header, multiSelect, allowsOther, options }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
        header = try c.decodeIfPresent(String.self, forKey: .header)
        multiSelect = try c.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
        allowsOther = try c.decodeIfPresent(Bool.self, forKey: .allowsOther) ?? false
        options = try c.decodeIfPresent([Option].self, forKey: .options) ?? []
    }
}

/// The `cmuxMobile` object of a push (v1 from a 0.11 Worker, v2 from 0.12).
public struct PushPayload: Codable, Sendable, Equatable {
    public static let userInfoKey = "cmuxMobile"

    public enum State: String, Codable, Sendable { case waiting, finished, failed, notified }

    public var v: Int
    public var mac: String?
    public var macName: String?
    public var kind: PushKind
    public var eventId: String?
    public var agent: String?
    public var place: String?
    public var workspace: String?
    public var workspaceId: String?
    public var tabId: String?
    public var sessionId: String?
    public var permissionId: String?
    public var conversationId: String?
    public var notificationId: String?
    public var title: String?
    public var body: String?
    public var options: [PushOption]
    /// What a phone may answer, the same rule as the Feed (`ACPPermissionRequest.phoneOptions`):
    /// with a single-use Allow, Allow once and the one-time reject only; acpmux refuses a lasting
    /// grant from a phone (`remote.lasting_grant_refused`). Without one, the options as sent, so
    /// acpmux's refusal says why rather than the prompt showing a lone Deny.
    public var phoneOptions: [PushOption] {
        guard options.contains(where: { $0.kind == .allowOnce }) else { return options }
        return options.filter { $0.kind == .allowOnce || $0.kind == .rejectOnce }
    }
    public var questions: [PushQuestion]
    public var tail: [String]
    public var state: State?
    /// False when the phone turned Show previews off: the banner is generic.
    public var previews: Bool
    /// A terminal notification whose poster takes a typed reply (`notify --reply`).
    public var replyable: Bool
    /// The acpmux prompt's `decisionNonce` and daemon run (`personInstance`):
    /// only in a sealed push, so a mailbox Allow can be signed offline.
    public var decisionNonce: String?
    public var personInstance: String?
    /// When the Mac posted it (Unix seconds; sealed pushes): an old one replayed later gets no buttons.
    public var postedAt: Int?

    public init(v: Int = 2, mac: String?, macName: String? = nil, kind: PushKind, eventId: String? = nil, agent: String? = nil,
                place: String? = nil, workspace: String? = nil, workspaceId: String? = nil, tabId: String? = nil,
                sessionId: String? = nil, permissionId: String? = nil, conversationId: String? = nil, notificationId: String? = nil,
                title: String? = nil, body: String? = nil, options: [PushOption] = [], questions: [PushQuestion] = [],
                tail: [String] = [], state: State? = nil, previews: Bool = true, replyable: Bool = false,
                decisionNonce: String? = nil, personInstance: String? = nil, postedAt: Int? = nil) {
        self.v = v
        self.mac = mac
        self.macName = macName
        self.kind = kind
        self.eventId = eventId
        self.agent = agent
        self.place = place
        self.workspace = workspace
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.sessionId = sessionId
        self.permissionId = permissionId
        self.conversationId = conversationId
        self.notificationId = notificationId
        self.title = title
        self.body = body
        self.options = options
        self.questions = questions
        self.tail = tail
        self.state = state
        self.previews = previews
        self.replyable = replyable
        self.decisionNonce = decisionNonce
        self.personInstance = personInstance
        self.postedAt = postedAt
    }

    enum CodingKeys: String, CodingKey {
        case v, mac, macName, kind, eventId, agent, place, workspace, workspaceId, tabId, sessionId, permissionId, conversationId
        case notificationId, title, body, options, questions, tail, state, previews, replyable, decisionNonce, personInstance
        case postedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            guard let value = try? c.decodeIfPresent(String.self, forKey: key), !value.isEmpty else { return nil }
            return value
        }
        guard let kind = text(.kind).flatMap(PushKind.init(rawValue:)) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown push kind")
        }
        self.kind = kind
        v = (try? c.decodeIfPresent(Int.self, forKey: .v)) ?? 1
        // A sealed push the service extension could not open (v3) carries no
        // content to act on: none of its buttons may reach the Mac.
        guard v < 3 else {
            throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "an unopened sealed push")
        }
        mac = text(.mac)
        macName = text(.macName)
        eventId = text(.eventId)
        agent = text(.agent)
        place = text(.place)
        workspace = text(.workspace)
        workspaceId = text(.workspaceId)
        tabId = text(.tabId)
        sessionId = text(.sessionId)
        permissionId = text(.permissionId)
        conversationId = text(.conversationId)
        notificationId = text(.notificationId)
        title = text(.title)
        body = text(.body)
        // A malformed list costs that list, never the whole notification.
        options = (try? c.decodeIfPresent([PushOption].self, forKey: .options)) ?? []
        questions = (try? c.decodeIfPresent([PushQuestion].self, forKey: .questions)) ?? []
        tail = (try? c.decodeIfPresent([String].self, forKey: .tail)) ?? []
        state = text(.state).flatMap(State.init(rawValue:))
        previews = (try? c.decodeIfPresent(Bool.self, forKey: .previews)) ?? true
        replyable = (try? c.decodeIfPresent(Bool.self, forKey: .replyable)) ?? false
        decisionNonce = text(.decisionNonce)
        personInstance = text(.personInstance)
        postedAt = try? c.decodeIfPresent(Int.self, forKey: .postedAt)
    }

    /// Reads `userInfo["cmuxMobile"]`; nil for any other notification.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let object = userInfo[Self.userInfoKey], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let payload = try? JSONDecoder().decode(PushPayload.self, from: data) else { return nil }
        self = payload
    }

    /// The `userInfo` a local notification carrying this payload uses.
    public var userInfo: [AnyHashable: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return [Self.userInfoKey: object]
    }

    /// One question, one choice, with 1 to 4 listed options: answered by its buttons.
    public var isSingleChoice: Bool {
        guard kind == .question, questions.count == 1, let q = questions.first else { return false }
        return !q.multiSelect && (1...PushActions.maxOptionButtons).contains(q.options.count)
    }

    /// The category the Worker picks for this payload (PROTOCOL.md).
    public var category: PushCategory {
        switch kind {
        case .question: isSingleChoice ? .question : .questionForm
        case .permission: .permission
        case .completed: .completed
        case .failed: .failed
        case .chief: .chief
        case .terminal: .terminal
        }
    }

    /// The APNs thread this push belongs to (PROTOCOL.md `thread-id`).
    public var threadIdentifier: String {
        let mac = mac ?? ""
        if let sessionId { return "\(mac):\(sessionId)" }
        if let tabId { return "\(mac):\(tabId)" }
        if let conversationId { return "\(mac):chief:\(conversationId)" }
        return mac
    }

    /// What the banner names the Mac: its name, else "your Mac".
    public var macDisplayName: String { macName ?? String(localized: "your Mac") }

    /// The words a person reads for the place: the workspace title, else the folder.
    public var placeName: String? { workspace ?? place }
}
