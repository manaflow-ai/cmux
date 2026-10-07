import Foundation
import Testing
@testable import CmuxNextDaemon

private struct ConversationRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// One client, one owner and the messages between them (see
/// ConversationProjectionPropertyTests).
struct ConversationWorld {
    private struct Request { var clientMsgID: String; var author: String; var empty: Bool; var connection: Int }
    private struct Reply { var clientMsgID: String; var result: Result<UInt64, ReplyError>; var connection: Int }
    private struct Event { var rev: UInt64; var change: ConversationChange; var connection: Int }
    struct ReplyError: Error { var reason: String }

    private var random: ConversationRandom
    var owner = ReferenceOwner()
    var client: ReferenceClient
    private var requests: [Request] = []
    private var replies: [Reply] = []
    private var events: [Event] = []
    private var connection = 0
    private var counter = 0
    /// Every id the user sent that the owner did not reject.
    private var sentIDs: Set<String> = []

    init(seed: UInt64) {
        random = ConversationRandom(state: seed)
        client = ReferenceClient(mirror: ConversationMirror(snapshot: ReferenceOwner().snapshot()))
    }

    mutating func step() {
        switch Int.random(in: 0..<100, using: &random) {
        case 0..<20: userSend()
        case 20..<40: serve()
        case 40..<48: otherSend()
        case 48..<75: deliverEvent()
        case 75..<95: deliverReply()
        default: reconnect()
        }
    }

    mutating func drain() {
        while !requests.isEmpty || !replies.isEmpty || !events.isEmpty {
            serve()
            while !events.isEmpty { deliverEvent(faults: false) }
            while !replies.isEmpty { deliverReply() }
        }
        if client.mirror.rev != owner.rev { resnapshot() }
        client.log.settle(against: client.mirror)
    }

    func visibleConfirmedIDs() -> [String] { client.mirror.tail.map(\.clientMsgID) }

    func checkInvariants() {
        let confirmed = Set(visibleConfirmedIDs())
        // No send is visible twice (confirmed and pending at once).
        for entry in client.log.entries {
            #expect(!confirmed.contains(entry.clientMsgID), "\(entry.clientMsgID) visible twice")
        }
        #expect(confirmed.count == client.mirror.tail.count, "a confirmed id repeats")
        // Nothing the user sent is lost: it is pending, or the owner has it.
        let owned = Set(owner.messages.map(\.clientMsgID))
        let pending = Set(client.log.entries.map(\.clientMsgID))
        for id in sentIDs { #expect(owned.contains(id) || pending.contains(id), "\(id) lost") }
        // The mirror never runs ahead of the owner.
        #expect(client.mirror.rev <= owner.rev)
    }

    private mutating func userSend() {
        counter += 1
        let id = "u\(counter)"
        let empty = Int.random(in: 0..<10, using: &random) == 0
        client.log.add(PendingConversationSend(clientMsgID: id, conversation: "c", parts: [], replyTo: nil, createdAt: .distantPast))
        if !empty { sentIDs.insert(id) }
        requests.append(Request(clientMsgID: id, author: "user_local", empty: empty, connection: connection))
    }

    private mutating func serve() {
        guard !requests.isEmpty else { return }
        let request = requests.removeFirst()
        guard request.connection == connection else { return }
        commit(request, connection: connection)
    }

    private mutating func commit(_ request: Request, connection: Int) {
        switch owner.send(clientMsgID: request.clientMsgID, author: request.author, empty: request.empty) {
        case .success(let result):
            if let change = result.change { events.append(Event(rev: result.rev, change: change, connection: connection)) }
            replies.append(Reply(clientMsgID: request.clientMsgID, result: .success(result.rev), connection: connection))
        case .failure(let rejected):
            replies.append(Reply(clientMsgID: request.clientMsgID, result: .failure(ReplyError(reason: rejected.reason)), connection: connection))
        }
    }

    private mutating func otherSend() {
        counter += 1
        if case .success(let result) = owner.send(clientMsgID: "o\(counter)", author: "agent_mux", empty: false), let change = result.change {
            events.append(Event(rev: result.rev, change: change, connection: connection))
        }
    }

    private mutating func deliverEvent(faults: Bool = true) {
        guard !events.isEmpty else { return }
        let event = events.removeFirst()
        guard event.connection == connection else { return }
        let roll = faults ? Int.random(in: 0..<20, using: &random) : 10
        if roll == 0 { return } // lost; the next event shows a gap
        apply(event)
        if roll == 1 { apply(event) } // duplicated
    }

    private mutating func apply(_ event: Event) {
        if client.mirror.apply(rev: event.rev, change: event.change) == .gap { resnapshot() }
        client.log.settle(against: client.mirror)
    }

    private mutating func deliverReply() {
        guard !replies.isEmpty else { return }
        let reply = replies.removeFirst()
        guard reply.connection == connection else { return }
        switch reply.result {
        case .success(let rev): client.log.acknowledge(reply.clientMsgID, rev: rev)
        case .failure(let error): client.log.reject(reply.clientMsgID, reason: error.reason)
        }
        client.log.settle(against: client.mirror)
    }

    private mutating func resnapshot() {
        client.mirror.reset(owner.snapshot())
        client.log.settle(against: client.mirror)
    }

    /// The connection drops: each in-flight request may or may not have reached
    /// the owner; replies and events in flight are lost. The client resyncs and
    /// resends what is still sending, with the same keys.
    private mutating func reconnect() {
        let inFlight = requests.filter { $0.connection == connection }
        for request in inFlight where Bool.random(using: &random) {
            _ = owner.send(clientMsgID: request.clientMsgID, author: request.author, empty: request.empty)
        }
        connection += 1
        requests.removeAll()
        replies.removeAll()
        events.removeAll()
        resnapshot()
        for entry in client.log.resendable {
            let empty = !sentIDs.contains(entry.clientMsgID)
            requests.append(Request(clientMsgID: entry.clientMsgID, author: "user_local", empty: empty, connection: connection))
        }
    }
}
