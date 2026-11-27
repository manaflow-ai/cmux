/// Runs each ``ObservationStream`` evaluation as one task of the app's main-thread scheduler
/// (plans/cmux-next/main-thread-scheduling.md, G1): the scheduler publishes it on its board with the
/// stream's site as the owner, so the stall watchdog names it, and charges its time to the frame, so the
/// budgeted work after a long evaluation yields. The scheduler lives in a package above this one
/// (CmuxNextWakeups' `MainFrameBudget`); the app installs its adapter once at the composition root
/// (``ObservationSite/evaluations``). With none installed (a test, a tool), an evaluation runs as before,
/// outside any scheduled task.
///
/// ```swift
/// // CmuxNextWakeups, the adapter:
/// func evaluate<T>(at site: ObservationSite, _ body: () -> T) -> T {
///     budget.run(.visible, owner: owner(of: site), body)
/// }
/// ```
@MainActor
public protocol ObservationEvaluationRunner: AnyObject {
    /// Runs `body`, one evaluation of the stream made at `site`, as a scheduled main-thread task, and returns its value.
    func evaluate<T>(at site: ObservationSite, _ body: () -> T) -> T
}

extension ObservationSite: Hashable {
    /// The site's name on the scheduler's board and in its stall records: `#fileID:#line`, the same text as
    /// ``ObservationWakes/bySite``.
    package var name: String { "\(fileID):\(line)" }

    /// The process's runner of stream evaluations: the app's main-thread scheduler, installed once at the
    /// composition root (`MainWorkScheduler.app()`); nil runs every evaluation unscheduled. One process-wide
    /// value because every `ObservationStream` (about 400 call sites, made wherever a value is observed) must
    /// run on the one scheduler the app has, and none of them is handed it: the stream stays the plain value
    /// of the system `Observations` call shape (arch exception mts-1-observation-budget).
    @MainActor package static var evaluations: (any ObservationEvaluationRunner)?

    /// Runs `body` (one evaluation of a stream made here) on the installed runner, or directly with none.
    @MainActor
    package func evaluate<T>(_ body: () -> T) -> T {
        guard let runner = Self.evaluations else { return body() }
        return runner.evaluate(at: self, body)
    }

    /// Two sites are one when they are the same `#fileID` literal at the same line (the literal's address:
    /// no string is read or hashed).
    public static func == (lhs: ObservationSite, rhs: ObservationSite) -> Bool {
        lhs.line == rhs.line && lhs.fileAddress == rhs.fileAddress
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(fileAddress)
        hasher.combine(line)
    }

    /// The `#fileID` literal's address (a `#fileID` is always stored as a pointer; a single-scalar literal,
    /// which no call site passes, is keyed by its scalar).
    private var fileAddress: UInt {
        fileID.hasPointerRepresentation ? UInt(bitPattern: fileID.utf8Start) : UInt(fileID.unicodeScalar.value)
    }
}
