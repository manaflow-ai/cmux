/// A request waiting for its reply, and when it was sent while a recorder times replies (nil
/// without one, and once its deadline passed: a late reply is not timed).
struct PendingRequest {
    var waiter: LineTransport.Waiter
    var sent: DaemonWireStats.RequestStamp?
}

/// The requests of one connection that wait for a reply: a dictionary by id plus a ring of ids in send
/// order, so a reply by id and the id-less error's oldest request are both O(1) amortized. Mojo's
/// `InterfaceEndpointClient` keeps its responders the same way, in a map by request id
/// (mojo/public/cpp/bindings/lib/interface_endpoint_client.cc, `async_responders_`).
///
/// An answered id leaves the dictionary at once and the ring lazily: the oldest-request lookup skips ids
/// that no longer wait, and the ring is compacted whenever it holds more than twice the waiting ids, so it
/// stays O(waiting) even while one old request never gets its reply.
nonisolated struct PendingRequests {
    private var byID: [UInt64: PendingRequest] = [:]
    /// Ids in send order; those before `head` and those not in `byID` no longer wait.
    private var ring: [UInt64] = []
    private var head = 0

    var count: Int { byID.count }
    var isEmpty: Bool { byID.isEmpty }
    /// Ids the ring holds, answered ones included: its space bound (tests).
    var ringCount: Int { ring.count }

    subscript(id: UInt64) -> PendingRequest? { byID[id] }

    /// Adds `id`, sent after every id added before it.
    mutating func append(_ request: PendingRequest, id: UInt64) {
        byID[id] = request
        ring.append(id)
        compactIfSparse()
    }

    /// Replaces a waiting request's entry in place; its send order is kept.
    mutating func replace(id: UInt64, with request: PendingRequest) {
        guard byID[id] != nil else { return }
        byID[id] = request
    }

    /// Takes `id` out; nil when it does not wait.
    mutating func remove(id: UInt64) -> PendingRequest? {
        guard let request = byID.removeValue(forKey: id) else { return nil }
        dropAnsweredHead()
        compactIfSparse()
        return request
    }

    /// The oldest id that still waits.
    mutating func oldestID() -> UInt64? {
        dropAnsweredHead()
        return ring[checked: head]
    }

    /// Takes every waiting request out, in send order.
    mutating func removeAllInSendOrder() -> [PendingRequest] {
        let requests = ring.dropFirst(head).compactMap { byID[$0] }
        byID.removeAll()
        ring.removeAll()
        head = 0
        return requests
    }

    private mutating func dropAnsweredHead() {
        while let id = ring[checked: head], byID[id] == nil { head += 1 }
    }

    /// Rebuilds the ring from the waiting ids once it holds more than twice as many: each rebuild is
    /// paid for by the answers since the last one.
    private mutating func compactIfSparse() {
        guard ring.count > 2 * byID.count + 32 else { return }
        ring = ring.dropFirst(head).filter { byID[$0] != nil }
        head = 0
    }
}
