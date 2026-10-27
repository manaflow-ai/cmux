import CmuxNextCompat
public import CmuxNextMetrics
public import CmuxNextSettings
import CmuxNextSignposts
public import CmuxNextTrace
import CmuxNextWakeups

/// One control-socket request from the line read to the reply sent (p09-observability task 115): the
/// accept-to-reply part of `control.request`, its parsed, queued and dispatched marks, the caller's flow, and the
/// `automation.request.<class>` and `automation.main_queue_us` histograms. Chrome traces an IPC message the same
/// way: a slice from its receipt to its reply, with the sender's flow id
/// (ipc/ipc_message_utils.cc, `TRACE_IPC_MESSAGE_SEND` and mojo/public/cpp/bindings/lib/message.cc,
/// `TRACE_EVENT_WITH_FLOW`).
///
/// Ring records (name `control.request`, bit 63 of every `arg0` set, which the queue's own slice of task 042
/// never sets):
/// - AB when the connection's consumer takes the line (a pipelined line's wait behind the earlier lines of its
///   connection is outside it), AE at the reply; both carry the slice's async id in `arg1`. AB `arg0`: the connection
///   id in bits 0-31. AE `arg0`: ``descriptor`` in bits 0-47 and the ``Outcome`` in bits 48-55.
/// - An instant (async id in `arg1`) for each ``Mark``: `arg0` the descriptor in bits 0-47 and the mark in bits
///   56-62.
/// - When the caller sent a `flow`, a flow-out at the parse (`arg1` the flow; the CLI has no ring, so the flow
///   starts here) whose action run ends it with a flow-in at `action.commit` (``ActionRunInput/flow``).
///
/// The guard: a scope that is released before ``replied()`` writes its end with ``Outcome/abandoned``
/// (`deinit`), so a written begin always gets its end, whatever path the request took.
public final class ControlRequestScope: Sendable {
    /// Who sent a request: the descriptor's bits 32-39. Fixed codes; 0 is "not parsed yet".
    public enum Source: UInt8, Sendable, CaseIterable {
        /// The `cmux` command line, from a terminal or a script (`source: cli`, or none named).
        case cli = 1
        /// `cmux mcp serve` with no agent session (`source: mcp`; from a CLI older than `source`, `origin: mcp`).
        case mcp = 2
        /// An agent's CLI or MCP server (`source: agent`; from an older CLI, `caller.agent_session`).
        case agent = 3
        /// A cmux app inside this process (an in-process connection or a calling app).
        case app = 4

        /// The source a request line names in its top-level `source` (``ControlRequest/source``): `cli`, `mcp` or
        /// `agent`. Nil for any other text: a line never claims ``app``.
        public init?(wire: String) {
            switch wire {
            case "cli": self = .cli
            case "mcp": self = .mcp
            case "agent": self = .agent
            default: return nil
            }
        }

        /// The source of `request` on `connection`: ``app`` in process or for a calling app, else the source the
        /// line named, else (a CLI older than `source`) read from its params.
        public init(_ request: ControlRequest, connection: ControlConnectionID) {
            if connection == .inProcess || request.callerApp != nil {
                self = .app
            } else if let named = request.source {
                self = named
            } else if case .object(let caller) = request.params["caller"], caller["agent_session"]?.stringValue?.isEmpty == false {
                self = .agent
            } else if request.params["origin"]?.stringValue == "mcp" {
                self = .mcp
            } else {
                self = .cli
            }
        }
    }

    /// How the request ended: the AE's bits 48-55. Fixed codes.
    public enum Outcome: UInt8, Sendable {
        /// A v2 reply with `ok: true`.
        case ok = 0
        /// A v2 reply with `ok: false`.
        case failed = 1
        /// A reply that is not a v2 method's (`ping`, `auth`, a line that did not decode).
        case plain = 2
        /// Released with no reply sent (the guard).
        case abandoned = 3
    }

    /// A point inside the request: an instant's bits 56-62. Fixed codes.
    public enum Mark: UInt8, Sendable {
        /// Decoded off the main thread.
        case parsed = 1
        /// Accepted by the main-actor work queue.
        case queued = 2
        /// Started on the main thread.
        case dispatched = 3
    }

    /// Bit 63 of every `arg0` this scope writes.
    static let marker: UInt64 = 1 << 63
    private static var name: UInt16 { SignpostName.controlRequest.rawValue }
    private static var categoryBit: UInt8 { SignpostCategory.control.traceBit }

    private let runtime: TraceRuntime
    private let metrics: Metrics
    /// The slice's async id; 0 when the `control` category was off at the line read (nothing is written).
    private let id: UInt64
    private let acceptedAt: ContinuousClock.Instant
    /// ``descriptor`` once the line decoded; 0 before.
    private let packed = Atomic<UInt64>(0)
    /// The outcome the router chose (``noteResult(ok:)``), as `Outcome.rawValue`.
    private let result = Atomic<UInt8>(Outcome.plain.rawValue)
    private let ended = Atomic<Bool>(false)

    /// Opens the scope of a line `connection`'s consumer just took: the AB when the `control` category records.
    public init(connection: ControlConnectionID, runtime: TraceRuntime = .shared) {
        self.runtime = runtime
        metrics = Metrics(runtime: runtime)
        acceptedAt = .now
        guard runtime.isEnabled(categoryBit: Self.categoryBit) else {
            id = 0
            return
        }
        let id = runtime.nextAsyncScope()
        let written = runtime.write(name: Self.name, categoryBit: Self.categoryBit, phase: .asyncBegin, flags: .asyncID,
                                    arg0: Self.marker | (connection.rawValue & 0xFFFF_FFFF), arg1: id)
        self.id = written ? id : 0
    }

    deinit {
        end(.abandoned)
    }

    /// The decoded request's numbers: the method's ``methodID(_:)`` in bits 0-31, its ``Source`` in bits 32-39
    /// and its class (position in `HistogramID.MethodClass.allCases` + 1) in bits 40-47; 0 before the parse.
    public var descriptor: UInt64 { packed.load(ordering: .relaxed) }

    /// The line decoded as `request` on `connection`: keeps its numbers, writes the parsed mark, starts the
    /// caller's flow, and returns `request` carrying this scope to the work queue.
    @discardableResult
    public func parsed(_ request: ControlRequest, connection: ControlConnectionID) -> ControlRequest {
        var request = request
        request.scope = self
        let methodClass = Self.methodClass(request.method)
        let classCode = UInt64(truncatingIfNeeded: HistogramID.MethodClass.allCases.firstIndex(of: methodClass) ?? 0) + 1
        let source = UInt64(truncatingIfNeeded: Source(request, connection: connection).rawValue)
        let descriptor = Self.methodID(request.method) | source << 32 | classCode << 40
        packed.store(descriptor, ordering: .relaxed)
        mark(.parsed)
        guard id != 0, let flow = request.flow else { return request }
        runtime.write(name: Self.name, categoryBit: Self.categoryBit, phase: .flowOut, arg0: Self.marker | descriptor,
                      arg1: flow)
        return request
    }

    /// Writes `mark` when the scope's begin was written.
    public func mark(_ mark: Mark) {
        guard id != 0 else { return }
        runtime.write(name: Self.name, categoryBit: Self.categoryBit, phase: .instant, flags: .asyncID,
                      arg0: Self.marker | UInt64(truncatingIfNeeded: mark.rawValue) << 56 | descriptor, arg1: id)
    }

    /// Started on the main thread after waiting `waited` there: the dispatched mark and `automation.main_queue_us`.
    public func dispatched(after waited: Duration) {
        metrics.record(.automationMainQueue, duration: waited)
        mark(.dispatched)
    }

    /// The router answered the v2 request with `ok` (true) or an error.
    public func noteResult(ok: Bool) {
        result.store(ok ? Outcome.ok.rawValue : Outcome.failed.rawValue, ordering: .relaxed)
    }

    /// `result`, the router's answer to the request, after noting its outcome on `scope` (``noteResult(ok:)``).
    public static func noting(_ result: Result<JSONValue, ControlError>, on scope: ControlRequestScope?) -> Result<JSONValue, ControlError> {
        if case .success = result { scope?.noteResult(ok: true) } else { scope?.noteResult(ok: false) }
        return result
    }

    /// The reply line is going to the connection: the AE and `automation.request.<class>`.
    public func replied() {
        end(Outcome(rawValue: result.load(ordering: .relaxed)) ?? .plain)
    }

    /// Ends the scope once: the AE when the begin was written, and the request's time when a v2 method decoded.
    private func end(_ outcome: Outcome) {
        guard !ended.exchange(true, ordering: .relaxed) else { return }
        let descriptor = self.descriptor
        if descriptor != 0 {
            let methodClass = HistogramID.MethodClass.allCases[checked: Int(truncatingIfNeeded: descriptor >> 40 & 0xFF) - 1] ?? .other
            metrics.record(.automationRequest(methodClass), duration: ContinuousClock.now - acceptedAt)
        }
        guard id != 0 else { return }
        runtime.writeEnd(name: Self.name, categoryBit: Self.categoryBit, phase: .asyncEnd, flags: .asyncID,
                         arg0: Self.marker | UInt64(truncatingIfNeeded: outcome.rawValue) << 48 | descriptor, arg1: id)
    }

    /// A method's number in the ring: the low 32 bits of its FNV-1a hash (``CrashKeySlots/stableKey(_:)``), the
    /// same in every build, so `trace.py` maps it back from the method names it knows.
    public static func methodID(_ method: String) -> UInt64 {
        CrashKeySlots.stableKey(method) & 0xFFFF_FFFF
    }

    /// The class `automation.request.<class>` records `method` under (the daemon's classes, task 013).
    public static func methodClass(_ method: String) -> HistogramID.MethodClass {
        if method == "debug.key" { return .terminalIO }
        if method.hasPrefix("browser.") { return .browser }
        if ["cloud.", "remote.", "session.transfer.", "mobile."].contains(where: method.hasPrefix) { return .cloud }
        if method.hasPrefix("feed.") || method.hasPrefix("debug.agent") { return .agent }
        if ["action.run", "action.batch", "palette.run", "tab.focus"].contains(method) { return .topology }
        if method == "file.open" { return .create }
        if method.hasPrefix("system.") || method == "snapshot.get"
            || [".list", ".get", ".status", ".describe", ".search", ".query", ".resolve", ".scopes"].contains(where: method.hasSuffix) {
            return .query
        }
        return .other
    }
}
