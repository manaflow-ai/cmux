/// A FIFO queue that releases consumed teardown requests in amortized constant time.
struct TerminalSurfaceRuntimeTeardownRequestQueue {
    private var incoming: [TerminalSurfaceRuntimeTeardownRequest] = []
    private var outgoing: [TerminalSurfaceRuntimeTeardownRequest] = []

    mutating func append(_ request: TerminalSurfaceRuntimeTeardownRequest) {
        incoming.append(request)
    }

    mutating func popFirst() -> TerminalSurfaceRuntimeTeardownRequest? {
        if outgoing.isEmpty {
            outgoing = Array(incoming.reversed())
            incoming.removeAll(keepingCapacity: true)
        }
        return outgoing.popLast()
    }
}
