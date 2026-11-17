public import Foundation
public import os

/// A Cloud start's step times, one app log line each (`cloud start step: NAME MS ms`), so the chat probe's
/// `select_marks_ms` (cmuxterm-hq `cloud_chat_app_probe.py`) splits the span from the machine's create to the chat's
/// start: the link, the harness login's owner check, guest and login reads, its transfer's round trips, and the
/// chat's tab and start. Each step runs from the one before it (or this clock's start) to its own end, so the steps
/// add up to the span. Names only, never an id, a path or a token.
///
/// A clock made while a ``CloudStartStepRecord`` is the task's ``CloudStartStepRecord/current`` also adds each step
/// there, so a run that answers (`cloud start-session`'s `stages_ms`) reports the steps its nested clocks logged.
@MainActor public final class CloudStartSteps {
    /// What every line starts with: the probe matches it.
    public nonisolated static let prefix = "cloud start step: "
    let log: (String) -> Void
    let now: () -> ContinuousClock.Instant
    private let record: CloudStartStepRecord?
    private var last: ContinuousClock.Instant
    /// Each step done so far and its whole milliseconds, in order: a start's answer carries them as `stages_ms`, so the
    /// caller (`cmux cloud start-chat`) names where a long start went without reading the app's log.
    public private(set) var recorded: [(step: String, ms: Int64)] = []

    public init(log: @escaping (String) -> Void, now: @escaping () -> ContinuousClock.Instant = { .now }) {
        (self.log, self.now) = (log, now)
        record = CloudStartStepRecord.current
        last = now()
    }

    /// Lines into the app's Cloud log (`app.cloud`), where the probe reads the start's other marks.
    public convenience init(logger: Logger) { self.init(log: { line in logger.info("\(line, privacy: .public)") }) }

    /// Logs `name`'s time since the step before it ended.
    public func done(_ name: String) {
        let end = now(), elapsed = last.duration(to: end)
        log(Self.line(name, elapsed))
        recorded.append((name, Self.milliseconds(elapsed)))
        record?.add(name, Int(Self.milliseconds(elapsed)))
        last = end
    }

    /// `cloud start step: NAME MS ms`, whole milliseconds, never negative.
    public nonisolated static func line(_ name: String, _ elapsed: Duration) -> String {
        "\(prefix)\(name) \(milliseconds(elapsed)) ms"
    }

    /// Whole milliseconds of `elapsed`, never negative.
    public nonisolated static func milliseconds(_ elapsed: Duration) -> Int64 {
        let (seconds, attoseconds) = elapsed.components
        return max(0, seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }
}

/// The steps every ``CloudStartSteps`` clock of one run marked, in the order they ended: a dotted name (`login.machine`,
/// `connect.link`) is a part of the undotted step that ends after it (`login`, `connect`). Names and milliseconds only.
@MainActor public final class CloudStartStepRecord {
    /// The record the clocks made in this task add to (none: they only log).
    @TaskLocal public static var current: CloudStartStepRecord?
    /// At most this many steps; a run that marks more keeps the first ones.
    public nonisolated static let kept = 64
    public private(set) var steps: [(name: String, ms: Int)] = []
    /// The machine's own phases of the chat's start (`session_new`, ...), when its daemon sent them.
    public var machine: [String: Int]?

    /// The run's span, set by ``recording(_:)``.
    public private(set) var total = 0

    public init() {}

    /// Runs `body` with a new record current, and answers what it returned and the record.
    public static func recording<T>(_ body: () async throws -> T) async throws -> (T, CloudStartStepRecord) {
        let record = CloudStartStepRecord(), began = ContinuousClock.now
        // concurrency-allow: the async overload of withValue binds inside the calling task (always current in an async
        // function), never in the thread's fallback storage that cx-bpcj is about (the shared-package rule exempts it too).
        let value = try await $current.withValue(record) { try await body() }
        record.total = Int(CloudStartSteps.milliseconds(began.duration(to: .now)))
        return (value, record)
    }

    func add(_ name: String, _ ms: Int) {
        if steps.count < Self.kept { steps.append((name, ms)) }
    }
}
