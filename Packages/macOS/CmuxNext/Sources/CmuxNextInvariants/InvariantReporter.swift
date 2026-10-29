#if DEBUG || CMUX_BENCH_HOOKS
public import Foundation

/// Turns the registry's new violations into report files, off the violating turn (plans/cmux-next/invariants-DESIGN.md
/// section 4): each batch is journaled at once (one entry); every violation still waiting shares one read of the
/// app's facts in one turn of its own after the frame (`post`), however many violations came; the files lane encodes
/// the rules' states and the report and writes it; then, back on the main actor (`deliver`), the ledger names the
/// report and keeps each state of at most ``InvariantViolation/stateLimit`` bytes. The composition root makes one and
/// sets it as the registry's ``InvariantRegistry/onReports``.
///
/// ```swift
/// let reporter = InvariantReporter(registry: registry, store: store, post: { mainWork.post(.background, owner: "...", $0) },
///                                  deliver: { delivery.run($0) }, journal: { batch in journal.append(batch) },
///                                  capture: { ["debug_focus": { focus.data() }] })
/// registry.onReports = { [weak reporter] in reporter?.take($0) }
/// ```
@MainActor
public final class InvariantReporter {
    /// The app's facts a report holds, each encoded as JSON off the main actor: its key in the report and the bytes.
    public typealias Facts = [String: @Sendable () -> Data]

    private weak var registry: InvariantRegistry?
    private let store: InvariantReportStore
    private let post: @MainActor (@escaping @MainActor () -> Void) -> Void
    private let deliver: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let journal: @MainActor ([InvariantViolation]) -> UInt64?
    private let capture: @MainActor () -> Facts
    /// New violations whose report waits for its capture turn.
    private var waiting: [InvariantRegistry.NewViolation] = []

    /// - Parameters:
    ///   - registry: The registry whose ledger names the reports.
    ///   - store: Where the reports go.
    ///   - post: Runs work in a turn of its own after this one (the app: a `.background` main task).
    ///   - deliver: Runs work on the main actor, from the files lane (the app: a `MainDelivery`).
    ///   - journal: Journals a batch now; returns the journal's last sequence number.
    ///   - capture: Reads the app's facts once per report, on the main actor (the encoding runs later, off it).
    public init(registry: InvariantRegistry, store: InvariantReportStore,
                post: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void,
                deliver: @escaping @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void,
                journal: @escaping @MainActor ([InvariantViolation]) -> UInt64?,
                capture: @escaping @MainActor () -> Facts) {
        self.registry = registry
        self.store = store
        self.post = post
        self.deliver = deliver
        self.journal = journal
        self.capture = capture
    }

    /// A pass's new violations (``InvariantRegistry/onReports``): journaled now, reported in the next capture turn.
    public func take(_ batch: [InvariantRegistry.NewViolation]) {
        guard !batch.isEmpty else { return }
        if let tail = journal(batch.map(\.violation)) {
            for item in batch { registry?.ledger.annotate(item.violation.seq, journalTail: tail) }
        }
        let first = waiting.isEmpty
        waiting += batch
        guard first else { return }
        post { [weak self] in self?.captureWaiting() }
    }

    /// Reads the facts once for every waiting violation and hands the encoding and the write to the files lane.
    private func captureWaiting() {
        guard let first = waiting.first else { return }
        let batch = waiting
        waiting = []
        let facts = capture()
        let violations = batch.map { (violation: $0.violation, state: $0.state) }
        let seqs = violations.map(\.violation.seq)
        // The registry lives as long as the app; the delivery holds it only until the ledger is annotated.
        store.write(first: first.violation, count: batch.count, {
            InvariantReporter.encode(violations, facts: facts)
        }, written: { [registry, deliver] url, states in
            deliver { InvariantReporter.written(url, seqs: seqs, states: states, in: registry) }
        })
    }

    /// The report file exists: the ledger names it, and keeps each rule's state that fits.
    private static func written(_ url: URL, seqs: [UInt64], states: [UInt64: Data], in registry: InvariantRegistry?) {
        let path = url.path(percentEncoded: false)
        for seq in seqs { registry?.ledger.annotate(seq, report: path, state: states[seq]) }
    }

    /// The report (pretty, sorted-key JSON: the facts, `created_at` and `violations`, each with its rule's state)
    /// and each violation's encoded state. Off the main actor.
    nonisolated static func encode(_ violations: [(violation: InvariantViolation, state: @Sendable () -> Data?)],
                                   facts: Facts) -> (file: Data, states: [UInt64: Data]) {
        var states: [UInt64: Data] = [:]
        var items: [Any] = []
        for item in violations {
            let state = item.state()
            if let state { states[item.violation.seq] = state }
            items.append(object(item.violation, state: state))
        }
        var report: [String: Any] = [:]
        for (key, read) in facts { report[key] = json(read()) }
        report["created_at"] = Date().formatted(.iso8601)
        report["violations"] = items
        let file = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return (file, states)
    }

    /// One violation as the report gives it (the fields of `debug.invariants`, with the whole state).
    nonisolated static func object(_ violation: InvariantViolation, state: Data?) -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var fields: [String: Any] = [
            "seq": violation.seq, "id": violation.id.rawValue, "host": violation.host, "detail": violation.detail,
            "subject": json(try? encoder.encode(violation.subject)), "trigger": json(try? encoder.encode(violation.trigger)),
            "state": json(state),
        ]
        if let tail = violation.journalTail { fields["journal_tail"] = tail }
        return fields
    }

    /// `data` parsed as JSON (a fragment too), or null.
    nonisolated static func json(_ data: Data?) -> Any {
        guard let data, let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return NSNull() }
        return value
    }
}
#endif
