/// Rebuilds unordered and partial lane messages from fragments. Incomplete
/// messages beyond `limit` are dropped oldest first (loss is allowed).
struct MessageReassembler {
    private struct Partial {
        var fragments: [[UInt8]?]
        var received = 0
    }

    let limit: Int
    private var partials: [UInt32: Partial] = [:]
    private var order: [UInt32] = []

    init(limit: Int = 64) {
        self.limit = limit
    }

    mutating func receive(id: UInt32, index: UInt16, count: UInt16, payload: [UInt8]) -> [UInt8]? {
        if count == 1 { return payload }
        var partial = partials[id] ?? Partial(fragments: Array(repeating: nil, count: Int(count)))
        guard partial.fragments.count == Int(count), partial.fragments[Int(index)] == nil else { return nil }
        if partials[id] == nil {
            order.append(id)
            if order.count > limit, let oldest = order.first {
                order.removeFirst()
                partials[oldest] = nil
            }
        }
        partial.fragments[Int(index)] = payload
        partial.received += 1
        if partial.received == Int(count) {
            partials[id] = nil
            order.removeAll { $0 == id }
            return partial.fragments.flatMap { $0 ?? [] }
        }
        partials[id] = partial
        return nil
    }
}
