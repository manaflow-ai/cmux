import CmuxNextWakeups

/// Writes startup trace records as Chrome Trace Event Format JSON, the JSON Array form: `[` then one event
/// per line, each line after the first starting with `,`, and `]` only when the trace closes. The format
/// lets the closing `]` be missing (Trace Event Format, "JSON Array Format"; Chrome's own
/// `base/trace_event/trace_log.cc` writer relies on it), so a launch that crashes leaves a file that
/// ui.perfetto.dev and chrome://tracing still load. Every write ends on an event boundary.
///
/// Times are `CLOCK_UPTIME_RAW` microseconds with three decimals, so trace.py merges this file with the
/// daemon's and CEF's on one clock.
struct StartupTraceEncoder: Sendable {
    let pid: Int32
    /// The encoded bytes not yet written.
    private(set) var bytes: [UInt8] = []
    private var events = 0

    init(pid: Int32, reserve: Int) {
        self.pid = pid
        bytes.reserveCapacity(reserve + 1_024)
    }

    /// Events encoded so far, metadata included.
    var eventCount: Int { events }

    /// Drops the encoded bytes (written, or lost to a failed file), keeping the buffer.
    mutating func clear() {
        bytes.removeAll(keepingCapacity: true)
    }

    /// The opening `[`, the process name and the main thread's name.
    mutating func header(mainThread: UInt64?) {
        append("[\n")
        beginEvent()
        append(#"{"name":"process_name","ph":"M","pid":"#); append(Int64(pid))
        append(#","tid":0,"args":{"name":"cmux"}}"#)
        if let mainThread {
            beginEvent()
            append(#"{"name":"thread_name","ph":"M","pid":"#); append(Int64(pid))
            append(#","tid":"#); append(mainThread)
            append(#","args":{"name":"main"}}"#)
        }
    }

    /// One record as one event.
    mutating func append(_ record: StartupTraceRecord) {
        beginEvent()
        append(#"{"name":""#)
        switch record.event {
        case .mark(let name): appendEscaped(name.utf8)
        case .task(let name): name.withUTF8Buffer { appendEscaped($0) }
        case .mainTurn: append("main_turn")
        case .laneJob(let lane, _): append("lane."); append(lane.description)
        }
        append(#"","cat":""#)
        switch record.event {
        case .mark(let name): append(name.hasPrefix("daemon.") ? "daemon" : "launch")
        case .task: append("startup_task")
        case .mainTurn: append("main")
        case .laneJob: append("lane")
        }
        if case .mark = record.event {
            append(#"","ph":"i","s":"p","ts":"#)
            appendMicroseconds(record.start)
        } else {
            append(#"","ph":"X","ts":"#)
            appendMicroseconds(record.start)
            append(#","dur":"#)
            appendMicroseconds(record.end > record.start ? record.end - record.start : 0)
        }
        append(#","pid":"#); append(Int64(pid))
        append(#","tid":"#); append(record.thread)
        if case .laneJob(_, let priority) = record.event {
            append(#","args":{"priority":""#); append(priority.description); append(#""}"#)
        }
        append("}")
    }

    /// The closing instant (how many records the ring dropped) and the closing `]`.
    mutating func footer(at nanos: UInt64, dropped: Int) {
        beginEvent()
        append(#"{"name":"startup_trace.closed","cat":"launch","ph":"i","s":"p","ts":"#)
        appendMicroseconds(nanos)
        append(#","pid":"#); append(Int64(pid))
        append(#","tid":0,"args":{"dropped":"#); append(Int64(dropped))
        append("}}\n]\n")
    }

    private mutating func beginEvent() {
        if events > 0 { append(",\n") }
        events += 1
    }

    private mutating func append(_ text: String) {
        bytes.append(contentsOf: text.utf8)
    }

    /// At most 20 digits: a small string, no heap allocation.
    private mutating func append(_ value: UInt64) {
        bytes.append(contentsOf: String(value).utf8)
    }

    private mutating func append(_ value: Int64) {
        if value < 0 { bytes.append(UInt8(ascii: "-")) }
        append(value.magnitude)
    }

    /// Nanoseconds as microseconds with three decimals (`1234.567`).
    private mutating func appendMicroseconds(_ nanos: UInt64) {
        append(nanos / 1_000)
        let fraction = nanos % 1_000
        bytes.append(UInt8(ascii: "."))
        bytes.append(UInt8(ascii: "0") + UInt8(fraction / 100))
        bytes.append(UInt8(ascii: "0") + UInt8(fraction / 10 % 10))
        bytes.append(UInt8(ascii: "0") + UInt8(fraction % 10))
    }

    /// A JSON string body: `"` and `\` escaped, control characters as `\u00XX`.
    private mutating func appendEscaped(_ text: some Sequence<UInt8>) {
        for byte in text {
            switch byte {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"):
                bytes.append(UInt8(ascii: "\\"))
                bytes.append(byte)
            case 0..<0x20:
                append(#"\u00"#)
                bytes.append(Self.hexDigit(byte >> 4))
                bytes.append(Self.hexDigit(byte & 0xF))
            default:
                bytes.append(byte)
            }
        }
    }

    private static func hexDigit(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? UInt8(ascii: "0") + nibble : UInt8(ascii: "a") + nibble - 10
    }
}
