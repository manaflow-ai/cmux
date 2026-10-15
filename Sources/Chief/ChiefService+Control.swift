import AppKit
import CmuxChief
import CmuxHomeCore
import Foundation
import MessagesLabHome

/// What `chief.status` reports.
struct ChiefControlStatus: Sendable {
    var started: Bool
    var startFailure: String?
    var home: String?
    var harness: String
    var harnessName: String
    var model: String
    var effort: String
    var unread: Int
    var conversationCount: Int
    var working: [String]
    var defaultConversation: String
}

/// One `chief.conversations` row.
struct ChiefControlConversation: Sendable {
    var id: String
    var title: String
    var preview: String
    var unread: Int
    var pinned: Bool
    var working: Bool
    var updatedAt: Date
}

/// One `chief.read` message.
struct ChiefControlMessage: Sendable {
    var id: String
    var seq: UInt64
    var authorID: String
    var author: String
    var authorKind: String
    var text: String
    var at: Date
    var parts: [String]
    var threadRoot: String?
}

/// The outcome of `chief.send`.
struct ChiefControlSendResult: Sendable {
    var conversation: String
    var messageID: String?
    /// The store holds the send until the owner is reachable.
    var queued: Bool
}

/// Why a `chief.*` request could not run.
enum ChiefControlFailure: Error, Sendable {
    case unavailable(String)
    case rejected(code: String, message: String)

    var code: String {
        switch self {
        case .unavailable: "unavailable"
        case .rejected(let code, _): code
        }
    }

    var message: String {
        switch self {
        case .unavailable(let message): message
        case .rejected(_, let message): message
        }
    }

    /// A ``HomeRejection`` as a socket error.
    static func from(_ rejection: HomeRejection) -> ChiefControlFailure {
        switch rejection {
        case .invalid(let reason) where reason == "unknown_conversation":
            .rejected(code: "not_found", message: String(localized: "socket.chief.error.unknownConversation",
                                                         defaultValue: "No Chief conversation has that id."))
        case .invalid(let reason) where reason == "approval_decided":
            .rejected(code: "conflict", message: String(localized: "socket.chief.error.approvalDecided",
                                                        defaultValue: "That approval was already answered."))
        case .invalid(let reason) where reason == "invalid_choice":
            .rejected(code: "invalid_params", message: String(localized: "socket.chief.error.invalidChoice",
                                                              defaultValue: "That is not one of the approval's options."))
        case .invalid(let reason) where reason == "invalid_name":
            .rejected(code: "invalid_params", message: String(localized: "socket.chief.error.invalidName",
                                                              defaultValue: "The sender name must have 1 to 60 characters."))
        case .invalid(let reason):
            .rejected(code: "invalid_params", message: reason)
        case .notAuthorized:
            .rejected(code: "not_authorized", message: ChiefStrings.rejection(rejection))
        case .ownerUnreachable, .indeterminate, .rateLimited:
            .rejected(code: "unavailable", message: ChiefStrings.rejection(rejection))
        }
    }
}

// The socket and CLI control surface (`chief.*`). Every entrypoint goes
// through the same owner and store the Home UI uses.
extension ChiefService {
    /// The started owner, waiting for its load when it is still loading.
    /// - Throws: ``ChiefControlFailure/unavailable(_:)`` when the Chief home could not be opened.
    func controlOwner() async throws -> ChiefConversationOwner {
        let load = controlOwnerLoad()
        do {
            return try await load.task.value
        } catch {
            throw ChiefControlFailure.unavailable(startFailure ?? load.failure)
        }
    }

    /// Starts the Chief and returns its owner's load, for a caller off the
    /// main actor to await, with the message for a failed load.
    func controlOwnerLoad() -> (task: Task<ChiefConversationOwner, any Error>, failure: String) {
        start()
        let failure = startFailure ?? ChiefStrings.unavailable
        if let ownerLoad { return (ownerLoad, failure) }
        // Not reached: start() always sets the load.
        return (Task<ChiefConversationOwner, any Error> { throw ChiefControlFailure.unavailable(failure) }, failure)
    }

    /// The conversation a request names; nil names the default Chief's.
    func controlConversationID(_ raw: String?) -> ConversationID {
        raw.map(ConversationID.init(_:)) ?? defaultConversationID
    }

    /// `chief.status`.
    func controlStatus() -> ChiefControlStatus {
        start()
        let engine = engineSettings
        return ChiefControlStatus(
            started: owner != nil,
            startFailure: startFailure,
            home: home?.root.path,
            harness: engine.resolvedHarness.rawValue,
            harnessName: engine.resolvedHarness.displayName,
            model: engine.resolvedModel,
            effort: engine.effort,
            unread: unreadCount,
            conversationCount: conversations.count,
            working: workingConversations.map(\.rawValue).sorted(),
            defaultConversation: defaultConversationID.rawValue)
    }

    /// `chief.conversations`: pinned first, then newest first (the Home list's order).
    func controlConversations() -> [ChiefControlConversation] {
        start()
        return conversations.map { row in
            ChiefControlConversation(id: row.id.rawValue, title: row.title, preview: row.preview, unread: row.unread,
                                     pinned: row.isPinned, working: isWorking(row.id), updatedAt: row.timestamp)
        }
    }

    /// `chief.send` without `from`: the user's message through the store,
    /// exactly as Return in the compose field sends plain text
    /// (`HomeStore.perform(.sendMessage)`), so the transcript shows it the same.
    ///
    /// - Throws: ``ChiefControlFailure``.
    func controlSendAsUser(text: String, conversation raw: String?) async throws -> ChiefControlSendResult {
        _ = try await controlOwner()
        guard let store else { throw ChiefControlFailure.unavailable(startFailure ?? ChiefStrings.unavailable) }
        let conversation = controlConversationID(raw)
        if store.isConfirmed(conversation) || store.summary(conversation) != nil {
            // Known: fall through to the send.
        } else if store.isInboxCurrent {
            throw ChiefControlFailure.from(.invalid("unknown_conversation"))
        }
        let key = IdempotencyKey.make()
        do {
            _ = try await store.perform(.sendMessage(conversation: conversation, parts: [.text(text)], threadRoot: nil), key: key)
            return ChiefControlSendResult(conversation: conversation.rawValue, messageID: nil, queued: false)
        } catch HomeSendState.pendingResend {
            return ChiefControlSendResult(conversation: conversation.rawValue, messageID: nil, queued: true)
        } catch HomeRejection.ownerUnreachable where !store.isOnline {
            // The store queued the send while offline (`offlineSendDeadline`).
            return ChiefControlSendResult(conversation: conversation.rawValue, messageID: nil, queued: true)
        } catch let rejection as HomeRejection {
            throw ChiefControlFailure.from(rejection)
        } catch {
            throw ChiefControlFailure.rejected(code: "internal_error", message: String(describing: error))
        }
    }

    /// The ``MessagesLabHomeView`` that shows `conversation` in a visible
    /// window: the key window first, then the main window, then any other.
    func controlVisibleTranscript(conversation raw: String?) -> MessagesLabHomeView? {
        controlVisibleHost(conversation: raw).flatMap(Self.transcript(of:))
    }

    /// The ``ChiefTranscriptView`` that shows `conversation` with its
    /// transcript in a visible window, in the same window order.
    func controlVisibleHost(conversation raw: String?) -> ChiefTranscriptView? {
        let conversation = controlConversationID(raw)
        var windows: [NSWindow] = []
        for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) + NSApp.orderedWindows
        where window.isVisible && !windows.contains(where: { $0 === window }) {
            windows.append(window)
        }
        for window in windows {
            guard let root = window.contentView else { continue }
            if let found = Self.findHost(in: root, conversation: conversation) { return found }
        }
        return nil
    }

    private static func findHost(in view: NSView, conversation: ConversationID) -> ChiefTranscriptView? {
        if view.isHidden { return nil }
        if let host = view as? ChiefTranscriptView {
            return host.conversation == conversation && transcript(of: host) != nil ? host : nil
        }
        for subview in view.subviews {
            if let found = findHost(in: subview, conversation: conversation) { return found }
        }
        return nil
    }

    private static func transcript(of host: ChiefTranscriptView) -> MessagesLabHomeView? {
        for case let transcript as MessagesLabHomeView in host.subviews where !transcript.isHidden {
            return transcript
        }
        return nil
    }
}

extension ChiefControlMessage {
    /// A committed message with its author's name and kind from `participants`.
    init(_ message: Message, participants: [Participant]) {
        let author = participants.first { $0.id == message.author }
        let kind: String
        switch author?.kind {
        case .human?: kind = "human"
        case .agent?: kind = author?.isChief == true ? "chief" : "agent"
        case nil: kind = "unknown"
        }
        self.init(id: message.id.rawValue, seq: UInt64(message.seq), authorID: message.author.rawValue,
                  author: author?.displayName ?? message.author.rawValue, authorKind: kind,
                  text: message.isRetracted ? "" : message.plainText, at: message.createdAt,
                  parts: message.isRetracted ? ["retracted"] : message.parts.map(Self.kind(of:)),
                  threadRoot: message.threadRoot?.rawValue)
    }

    static func kind(of part: MessagePart) -> String {
        switch part {
        case .text: "text"
        case .work: "work"
        case .approval: "approval"
        case .question: "question"
        case .attachment: "attachment"
        case .linkPreview: "link_preview"
        case .location: "location"
        }
    }
}
