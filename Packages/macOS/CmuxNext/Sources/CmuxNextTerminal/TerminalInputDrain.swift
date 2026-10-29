public import CmuxNextTerminalGeometry
public import Foundation

/// One record of a session's input, in the order the session produced it: everything a
/// ``TerminalSession`` sends to its ``TerminalIO`` goes through one ``TerminalInputLane``, so a
/// resize never overtakes input typed before it.
public nonisolated enum TerminalInputRecord: Sendable, Equatable {
    /// Encoded input from Ghostty (keys, mouse and focus reports, a paste), or bytes given back.
    case bytes(Data)
    /// The bytes Ghostty wrote for the key press the app is dispatching, with its latency slot's flow
    /// (``CmuxNextInputCore/InputLatencyToken/keyFlow``): a daemon terminal sends the flow with them, so the daemon
    /// stamps the key's stages. Any other IO takes them as ``bytes(_:)``.
    case keyBytes(Data, keyFlow: UInt64)
    case resize(TerminalGridSize, pixelWidth: Int, pixelHeight: Int)
    case focusGained
    /// Take over from the "Sized for" chip.
    case takeOverSize(setLatest: Bool)
    /// The user clicked a disconnected terminal: re-attach.
    case reconnect
    /// The mirror needs a full snapshot from the owner.
    case resync

    /// The latency slot flow of a key's bytes; 0 for any other record.
    public var keyFlow: UInt64 {
        if case .keyBytes(_, let keyFlow) = self { return keyFlow }
        return 0
    }

    /// Hands the record to the matching async call of `io` (``TerminalInputDrain/awaiting(_:)``).
    func deliver(to io: any TerminalIO) async {
        switch self {
        case .bytes(let data), .keyBytes(let data, _): await io.write(data)
        case .resize(let grid, let width, let height):
            await io.resize(cols: grid.columns, rows: grid.rows, pixelWidth: width, pixelHeight: height)
        case .focusGained: await io.focusGained()
        case .takeOverSize(let setLatest): await io.takeOverSize(setLatest: setLatest)
        case .reconnect: await io.reconnectRequested()
        case .resync: await io.resyncRequested()
        }
    }
}

/// Where a session's ``TerminalInputLane`` drains (``TerminalIO/inputDrain()``): a serial queue, and the
/// handler that takes each record on it in order. The handler must not block: it is the one thread hop
/// from Ghostty's write to the owner (the attach socket's writer, which drains on the same queue; the PTY's write queue).
public nonisolated struct TerminalInputDrain: Sendable {
    /// What the lane does after ``handle`` returned.
    public nonisolated enum Next: Sendable {
        /// Take the next record now.
        case next
        /// Keep every later record until the ``TerminalInputResume`` passed with this one is called:
        /// the record's work finishes elsewhere and the next one must not overtake it.
        case hold
    }

    public let queue: DispatchQueue
    public let handle: @Sendable (TerminalInputRecord, TerminalInputResume) -> Next

    public init(queue: DispatchQueue, handle: @escaping @Sendable (TerminalInputRecord, TerminalInputResume) -> Next) {
        self.queue = queue
        self.handle = handle
    }

    /// Drains into the async calls of an IO with no drain of its own (demos, tests): each record's call
    /// runs in a task and the lane holds until it returned, so the calls keep the lane's order.
    public static func awaiting(_ io: any TerminalIO) -> TerminalInputDrain {
        TerminalInputDrain(queue: DispatchQueue(label: "com.cmuxterm.next.terminal.input-await", qos: .userInitiated)) { record, resume in
            Task {
                await record.deliver(to: io)
                resume()
            }
            return .hold
        }
    }
}

/// Lets a lane held by ``TerminalInputDrain/Next/hold`` take its next record. Call it once, from any
/// thread, when the held record's work finished.
public nonisolated struct TerminalInputResume: Sendable {
    let ring: TerminalInputRing
    let wake: any DispatchSourceUserDataAdd

    public func callAsFunction() {
        ring.held.store(false, ordering: .releasing)
        wake.add(data: 1)
    }
}
