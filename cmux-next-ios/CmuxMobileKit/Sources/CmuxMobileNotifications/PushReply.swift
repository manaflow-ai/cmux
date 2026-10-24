import Foundation

/// What a person answered from a notification, on its way to the Mac: from a
/// button (the app delegate), the content extension's option rows, Submit or
/// composer (through `PushOutbox`), or a "Couldn't reach" Retry.
public struct PushReply: Codable, Sendable, Equatable, Identifiable {
    public enum Action: Codable, Sendable, Equatable {
        /// A single-choice option, by index in the first question, with the
        /// label the person saw: the Mac's option there must still read so
        /// (PR #24156 review M1), or nothing is sent.
        case option(Int, label: String)
        /// Every question's chosen labels, and its free text ("" for none), in question order.
        case answers(selected: [[String]], other: [String])
        /// An allow option's acpmux id.
        case allow(optionID: String)
        /// A reject option's acpmux id (nil: the first reject the prompt offers).
        case deny(optionID: String?)
        /// A text reply; `attachments` are file names in the outbox's attachments folder.
        case text(String, attachments: [String])

        /// Signed with the approval key after Face ID (verify/phone-approvals.md).
        public var needsFaceID: Bool {
            switch self {
            case .option, .answers, .allow: true
            case .deny, .text: false
            }
        }
    }

    public var id: UUID
    public var mac: String
    public var macName: String?
    public var kind: PushKind
    public var sessionId: String?
    public var permissionId: String?
    public var conversationId: String?
    public var workspaceId: String?
    public var tabId: String?
    public var eventId: String?
    public var action: Action
    public var createdAt: Date

    public init(id: UUID = UUID(), mac: String, macName: String? = nil, kind: PushKind, sessionId: String? = nil,
                permissionId: String? = nil, conversationId: String? = nil, workspaceId: String? = nil, tabId: String? = nil,
                eventId: String? = nil, action: Action, createdAt: Date = Date()) {
        self.id = id
        self.mac = mac
        self.macName = macName
        self.kind = kind
        self.sessionId = sessionId
        self.permissionId = permissionId
        self.conversationId = conversationId
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.eventId = eventId
        self.action = action
        self.createdAt = createdAt
    }

    /// A reply to `payload`'s Mac and target.
    public init?(payload: PushPayload, action: Action, id: UUID = UUID(), now: Date = Date()) {
        guard let mac = payload.mac else { return nil }
        self.init(id: id, mac: mac, macName: payload.macName, kind: payload.kind, sessionId: payload.sessionId,
                  permissionId: payload.permissionId, conversationId: payload.conversationId, workspaceId: payload.workspaceId,
                  tabId: payload.tabId, eventId: payload.eventId, action: action, createdAt: now)
    }

    /// The reply a notification button means, or nil for the default tap,
    /// "Answer…", Retry (which carries its own reply) or a button this payload does not offer.
    public init?(payload: PushPayload, button: PushAction, text: String? = nil, id: UUID = UUID(), now: Date = Date()) {
        let action: Action
        switch button {
        case .option(let index):
            guard payload.isSingleChoice, let q = payload.questions.first, q.options.indices.contains(index) else { return nil }
            action = .option(index, label: q.options[index].label)
        case .allowOnce:
            guard let option = payload.options.first(where: { $0.kind == .allowOnce }) else { return nil }
            action = .allow(optionID: option.id)
        case .allowAlways:
            // acpmux refuses a lasting grant from a phone (PushActions offers no such button).
            return nil
        case .deny:
            action = .deny(optionID: payload.options.first(where: { $0.kind == .rejectOnce })?.id ?? payload.options.first(where: \.isReject)?.id)
        case .reply, .terminalReply:
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            action = .text(trimmed, attachments: [])
        case .answer, .retry:
            return nil
        }
        self.init(payload: payload, action: action, id: id, now: now)
    }

    /// The key of a "Couldn't reach" notification's retry: only the reply's
    /// id. The reply itself stays in the app's own storage (`PushRetryStore`),
    /// so a remote push can never carry one in (PR #24156 review H1).
    public static let retryIDKey = "cmuxMobileRetry"

    /// The `userInfo` of the "Couldn't reach" notification that retries this reply.
    public var retryUserInfo: [AnyHashable: Any] { [Self.retryIDKey: id.uuidString] }
}
