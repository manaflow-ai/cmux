/// Counts the bytes that cross the Swift<->Rust bridge, per op, while a test has it on (Leo,
/// ask-5ad71ec59c: "bytes sent across the Swift<->Rust bridge per sidebar row (#59531 sent the whole
/// 157 KB settings file on every row)"). The bridge's choke points (`HomeRules.callData`,
/// `SettingsRust.call`, `RustSidebarClient.call`, `SidebarFaceBatch.run`) report each call to the meter
/// the current task runs under (a task-local, so no process-wide state and tests never see each other's
/// calls; bind it with `withValueInTask`); with none, a report reads one empty task-local and computes nothing, so the app never pays.
///
///     let meter = BridgeByteMeter()
///     BridgeByteMeter.$current.withValueInTask(meter) { fixture.remap() }   // CmuxNextActions
///     let sent = meter.reading.sent   // bytes Swift handed Rust
public final class BridgeByteMeter: Sendable {
    /// One op's calls and bytes.
    public struct Op: Sendable, Equatable {
        public var calls = 0, sent = 0, received = 0
        public init() {}
    }

    /// What crossed while the meter was on, by op.
    public struct Reading: Sendable, Equatable {
        public var ops: [String: Op] = [:]
        public init() {}
        public var calls: Int { ops.values.reduce(0) { $0 + $1.calls } }
        public var sent: Int { ops.values.reduce(0) { $0 + $1.sent } }
        public var received: Int { ops.values.reduce(0) { $0 + $1.received } }
        /// The ops by bytes sent, largest first, as `op calls/sent/received` lines.
        public var summary: String {
            ops.sorted { $0.value.sent > $1.value.sent }
                .map { "\($0.key) calls=\($0.value.calls) sent=\($0.value.sent) received=\($0.value.received)" }
                .joined(separator: "\n")
        }
    }

    /// The meter the current task's bridge calls report to; nil unless a test binds one.
    @TaskLocal public static var current: BridgeByteMeter?

    private let state = Mutex(Reading())

    public init() {}

    /// What crossed so far.
    public var reading: Reading { state.withLock { $0 } }

    /// Clears the counts.
    public func reset() { state.withLock { $0 = Reading() } }

    /// One bridge call of `op` that sent `sent` bytes and got `received` back, counted by the current
    /// task's meter if it has one.
    @inline(__always)
    public static func record(_ op: @autoclosure () -> String, sent: @autoclosure () -> Int, received: @autoclosure () -> Int) {
        guard let meter = current else { return }
        let name = op()
        meter.state.withLock { reading in
            reading.ops[name, default: Op()].calls += 1
            reading.ops[name, default: Op()].sent += sent()
            reading.ops[name, default: Op()].received += received()
        }
    }
}
