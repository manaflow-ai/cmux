import Foundation

/// Chrome trace (Perfetto) spans for the phone's user actions, in the format of acpmux's
/// `perf_trace.rs` (cmux#55505): set `CMUX_TRACE_FILE=<path>` and each finished span becomes one
/// complete event (`"ph":"X"`) in a JSON array that ui.perfetto.dev and chrome://tracing open.
/// One W3C trace id (32 hex digits) per user action, kept in `args.trace_id` on the action and on
/// every daemon request it makes; a request that carries it to the Mac sends it as
/// `_meta.traceId` (``meta``), so the Mac's spans line up with the phone's.
///
/// `ts` is wall-clock microseconds since 1970, so a phone trace and a Mac trace of the same action
/// merge on one time axis. Off when the variable is unset: no file, no work beyond one check.
public enum PhoneTrace {
    /// The trace id of the user action this task runs for (nil: none).
    @TaskLocal public static var traceID: String?
    /// The round trips the current action made (nil: no action).
    @TaskLocal static var trips: TripCount?
    /// Where the current action's spans go (the action's recorder; nil: nowhere).
    @TaskLocal static var sink: Recorder?

    /// The recorder for `CMUX_TRACE_FILE`, or nil when it is unset or cannot be created.
    public static let recorder: Recorder? = ProcessInfo.processInfo.environment["CMUX_TRACE_FILE"]
        .flatMap { $0.isEmpty ? nil : Recorder(path: $0) }

    /// `_meta` for a request this action sends (`{"traceId": ...}`), nil outside an action.
    public static var meta: [String: Any]? { traceID.map { ["traceId": $0] } }

    /// A fresh W3C trace id: 16 random bytes as 32 lowercase hex digits, never all zero.
    public static func newTraceID() -> String {
        var generator = SystemRandomNumberGenerator()
        let high = generator.next() as UInt64
        let low = (generator.next() as UInt64) | (high == 0 ? 1 : 0)
        return String(format: "%016llx%016llx", high, low)
    }

    /// Runs `body` as one user action named `name`: every daemon request it makes is a span with
    /// this action's trace id, and the action itself is a span whose args say how many round
    /// trips it took against its floor (`floor_round_trips`, the fewest it could take).
    /// Runs on the caller's actor (`isolation`), so a main-actor body stays there.
    public static func action<T>(_ name: String, floorRoundTrips: Int? = nil, args: [String: String] = [:],
                                 isolation: isolated (any Actor)? = #isolation,
                                 _ body: () async throws -> T) async rethrows -> T {
        try await action(name, floorRoundTrips: floorRoundTrips, args: args, recorder: recorder, isolation: isolation, body)
    }

    /// ``action(_:floorRoundTrips:args:_:)`` into `recorder` (tests pass their own).
    static func action<T>(_ name: String, floorRoundTrips: Int?, args: [String: String], recorder: Recorder?,
                          isolation: isolated (any Actor)? = #isolation,
                          _ body: () async throws -> T) async rethrows -> T {
        let id = traceID ?? newTraceID()
        let count = TripCount()
        let start = Recorder.now()
        defer {
            var fields: [String: Any] = args
            fields["round_trips"] = count.finish()
            if let floorRoundTrips { fields["floor_round_trips"] = floorRoundTrips }
            recorder?.record(name: name, category: "action", start: start, traceID: id, args: fields)
        }
        return try await $traceID.withValue(id, operation: {
            try await $trips.withValue(count, operation: {
                try await $sink.withValue(recorder, operation: { try await body() }, isolation: isolation)
            }, isolation: isolation)
        }, isolation: isolation)
    }

    /// Records one round trip to the Mac (a daemon request, or a batch in one write) of the
    /// current action, from `start` to now.
    public static func roundTrip(_ name: String, start: Int64, args: [String: Any] = [:]) {
        trips?.add()
        guard let sink, let traceID else { return }
        sink.record(name: name, category: "daemon", start: start, traceID: traceID, args: args)
    }

    /// One action's round-trip count, shared by the requests it makes concurrently. A request
    /// that ends after the action (work the action left running, such as the tree reload after a
    /// close: a `Task` inherits the task locals) is still a span but not one the action waited for.
    final class TripCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var finished = false
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { if !finished { count += 1 } } }
        /// Ends the count and returns it.
        func finish() -> Int { lock.withLock { finished = true; return count } }
    }

    /// Writes one JSON event per finished span. Perfetto reads the array without its closing `]`,
    /// so a killed app still leaves a readable trace.
    public final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private let handle: FileHandle
        private let pid = Int(ProcessInfo.processInfo.processIdentifier)
        /// The trace file.
        public let path: String

        public init?(path: String) {
            guard FileManager.default.createFile(atPath: path, contents: Data("[\n".utf8)),
                  let handle = FileHandle(forWritingAtPath: path) else { return nil }
            handle.seekToEndOfFile()
            self.handle = handle
            self.path = path
        }

        /// Now, in wall-clock microseconds since 1970 (the events' `ts`).
        public static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000_000) }

        public func record(name: String, category: String, start: Int64, traceID: String, args: [String: Any] = [:]) {
            var fields = args
            fields["trace_id"] = traceID
            let event: [String: Any] = [
                "name": name, "cat": category, "ph": "X", "ts": start, "dur": max(0, Self.now() - start),
                "pid": pid, "tid": Thread.isMainThread ? 1 : 2, "args": fields,
            ]
            guard var line = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
            line.append(contentsOf: Array(",\n".utf8))
            lock.withLock { handle.write(line) }
        }
    }
}
