/// One hop of a key press's flow through the app (``Signposter/flowHop(_:flow:ageMicroseconds:)``): the name the
/// `key.flow` signpost's `hop=` field carries (scripts/cmux-next/trace.py joins on it) and the fixed code its
/// ring record carries, so the ring alone tells the hops apart. A fixed set, not a `String`: no person's text
/// becomes a hop, and a hop costs no allocation.
///
/// ```swift
/// Signposter.key.flowHop(.appIOWrite, flow: flow, ageMicroseconds: age)
/// ```
public nonisolated enum KeyFlowHop: String, Sendable, CaseIterable {
    /// The app began dispatching the key-down (the press's first hop: its flow starts here).
    case appKeyDispatch = "app.key.dispatch"
    /// The key-down's dispatch returned.
    case appKeyDispatched = "app.key.dispatched"
    /// The key router handed the key to a terminal.
    case appKeyTerminal = "app.key.terminal"
    /// The terminal wrote the key's bytes for the daemon.
    case appIOWrite = "app.io_write"
    /// The daemon `send` request went out.
    case appSend = "app.send"
    /// The echo's output frame was decoded.
    case appOutputDecoded = "app.output.decoded"
    /// The echo's output reached the main actor.
    case appOutputReceived = "app.output.received"
    /// The echo's output was parsed into the terminal.
    case appOutputParsed = "app.output.parsed"
    /// The echo's frame went to its layer.
    case appFrameContents = "app.frame.contents"
    /// The first Core Animation commit after the dispatch.
    case appKeyCommit = "app.key.commit"
    /// The Core Animation commit that carries the echo's frame to the screen.
    case appFrameCommit = "app.frame.commit"

    /// The hop's number in its ring record (bits 0-7 of `arg0`). Fixed and nonzero: rings written by an older
    /// build decode with the same numbers, and a new hop takes the next free one.
    public var traceCode: UInt8 {
        switch self {
        case .appKeyDispatch: 1
        case .appKeyDispatched: 2
        case .appKeyTerminal: 3
        case .appIOWrite: 4
        case .appSend: 5
        case .appOutputDecoded: 6
        case .appOutputReceived: 7
        case .appOutputParsed: 8
        case .appFrameContents: 9
        case .appKeyCommit: 10
        case .appFrameCommit: 11
        }
    }

    /// ``rawValue`` as a literal in the binary: the `key.flow` emit passes its NUL-terminated bytes, where a small
    /// `String` would be copied to the heap for them.
    var staticName: StaticString {
        switch self {
        case .appKeyDispatch: "app.key.dispatch"
        case .appKeyDispatched: "app.key.dispatched"
        case .appKeyTerminal: "app.key.terminal"
        case .appIOWrite: "app.io_write"
        case .appSend: "app.send"
        case .appOutputDecoded: "app.output.decoded"
        case .appOutputReceived: "app.output.received"
        case .appOutputParsed: "app.output.parsed"
        case .appFrameContents: "app.frame.contents"
        case .appKeyCommit: "app.key.commit"
        case .appFrameCommit: "app.frame.commit"
        }
    }

    /// Whether the press's flow starts at this hop: its ring record is a flow out (`s`); every later hop is a
    /// flow in (`f`) with the same id, as Chrome binds a flow's steps (`TRACE_EVENT_WITH_FLOW*`,
    /// base/trace_event/common/trace_event_common.h).
    public var startsFlow: Bool { self == .appKeyDispatch }
}
