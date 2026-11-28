public import CmuxHomeCore
public import CmuxNextHomeModel
import Foundation
public import Observation

/// Home's message requests (plans/cmux-next/home-messaging-invites/DESIGN.md 2.3): the list
/// the sidebar's Message Requests button counts and its sheet shows, and the one path for
/// Accept, Decline and Block. An answer takes the request off at once and puts it back when
/// the owner refuses it.
@MainActor @Observable
public final class HomeMessageRequests {
    public private(set) var items: [HomeMessageRequest] = []
    @ObservationIgnored private let source: any HomeMessageRequestSource
    // task-owner: the one list read in flight; ends with its reply (a reload asked meanwhile runs once more)
    @ObservationIgnored private var reading: Task<Void, Never>?
    /// The read loop's state (`reading`, `again`) as the Rust rules keep it.
    @ObservationIgnored private var reads = RequestReads()
    /// Answers sent and not answered yet: a list read meanwhile does not show them again.
    @ObservationIgnored private var answering: Set<ConversationID> = []

    // The list's decisions are the Rust rules' (`cloud.requests_*`, cmux-home-rules
    // `cloud/requests.rs`); the reads, the answers and the task stay here.

    public init(source: any HomeMessageRequestSource) {
        self.source = source
    }

    /// Reads the list again; calls while a read runs coalesce into one more read.
    public func refresh() {
        guard step(.refresh) else { return }
        reading = Task { [weak self] in
            await self?.readLoop()
        }
    }

    /// Reads the list now and returns when it is applied.
    public func reload() async {
        if let reading {
            _ = step(.refresh)
            await reading.value
            return
        }
        refresh()
        await reading?.value
    }

    private func readLoop() async {
        // wakeup-allow: each pass awaits one read; it repeats only when refresh() asked again during that read
        repeat {
            // A failed read keeps the last list (offline, or no lease yet).
            if let listed = try? await source.messageRequests() {
                let request = RequestsListedRequest(listed: listed.map(RequestWire.init), answering: answering.map(\.rawValue).sorted())
                if let reply: RequestItems = try? HomeRules.call("cloud.requests_listed", request) {
                    items = reply.items.map(\.request)
                }
            }
        } while step(.readEnded)
        reading = nil
    }

    /// One step of the read loop; true: start a read now. Without an answer from the rules a
    /// refresh starts none and a read ends the loop.
    private func step(_ event: RequestReadEvent) -> Bool {
        guard let reply: RequestReadStep = try? HomeRules.call("cloud.requests_read_step", RequestReadStepRequest(state: reads, event: event)) else {
            if event == .readEnded { reads = RequestReads() }
            return false
        }
        reads = reply.state
        return reply.read
    }

    /// Accept, Decline or Block one request. Returns whether the owner took it.
    public func answer(_ conversation: ConversationID, _ answer: HomeRequestAnswer) async -> Bool {
        let take = RequestsTakeRequest(items: items.map(RequestWire.init), conversation: conversation.rawValue)
        let taken: RequestsTaken? = try? HomeRules.call("cloud.requests_take", take)
        if let taken { items = taken.items.map(\.request) }
        answering.insert(conversation)
        defer { answering.remove(conversation) }
        do {
            try await source.answer(conversation, answer)
            return true
        } catch {
            // The owner refused or was not reached: the request shows again where it was.
            if let taken {
                let restore = RequestsRestoreRequest(items: items.map(RequestWire.init), index: taken.index, request: taken.request)
                if let reply: RequestItems = try? HomeRules.call("cloud.requests_restore", restore) {
                    items = reply.items.map(\.request)
                }
            }
            return false
        }
    }
}

/// `HomeMessageRequest` on the `cloud.requests_*` and `cloud.source_message_request` wire
/// (cmux-home-rules `cloud/requests.rs` `Request`); `createdAt` passes through as encoded.
nonisolated struct RequestWire: Codable {
    var conversation: String
    var inviter: String
    var isGroup: Bool
    var title: String?
    var preview: String
    var createdAt: Date?
    var trusted: Bool

    init(conversation: String, inviter: String, isGroup: Bool, title: String?, preview: String, createdAt: Date?, trusted: Bool) {
        self.conversation = conversation
        self.inviter = inviter
        self.isGroup = isGroup
        self.title = title
        self.preview = preview
        self.createdAt = createdAt
        self.trusted = trusted
    }

    init(_ request: HomeMessageRequest) {
        conversation = request.conversation.rawValue
        inviter = request.inviter
        isGroup = request.isGroup
        title = request.title
        preview = request.preview
        createdAt = request.createdAt
        trusted = request.trusted
    }

    var request: HomeMessageRequest {
        HomeMessageRequest(conversation: ConversationID(rawValue: conversation), inviter: inviter, isGroup: isGroup, title: title,
                           preview: preview, createdAt: createdAt, trusted: trusted)
    }
}

private nonisolated struct RequestReads: Codable {
    var reading = false
    var again = false
}

private nonisolated enum RequestReadEvent: String, Encodable {
    case refresh, readEnded
}

private nonisolated struct RequestReadStepRequest: Encodable {
    var state: RequestReads
    var event: RequestReadEvent
}

private nonisolated struct RequestReadStep: Decodable {
    var state: RequestReads
    var read: Bool
}

private nonisolated struct RequestsListedRequest: Encodable {
    var listed: [RequestWire]
    var answering: [String]
}

private nonisolated struct RequestItems: Decodable {
    var items: [RequestWire]
}

private nonisolated struct RequestsTakeRequest: Encodable {
    var items: [RequestWire]
    var conversation: String
}

private nonisolated struct RequestsTaken: Decodable {
    var items: [RequestWire]
    var index: Int?
    var request: RequestWire?
}

private nonisolated struct RequestsRestoreRequest: Encodable {
    var items: [RequestWire]
    var index: Int?
    var request: RequestWire?
}
