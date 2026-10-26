/// The dirty observations of one scheduler, each with the ``ObservationCauses/Mark`` it got when
/// it became dirty, in the order they became dirty (p06-scheduler-206; VisibleObservation,
/// p06-scheduler-025, queues its flushes here).
///
/// An observation calls ``markDirty(_:)`` from its `withObservationTracking` `onChange`, which
/// runs once per read, so each observation is queued at most once until its apply reads again.
/// Each flush class takes its own: the ``InputResponsePass`` takes the person's
/// (``applyPersonCaused()``), the visible and automation classes take theirs with
/// ``apply(_:)``.
///
/// ```swift
/// let dirty = DirtyObservations(causes: causes)
/// pass.addSource(dirty)
/// withObservationTracking { model.title } onChange: {
///     MainActor.assumeIsolated { dirty.markDirty { view.reapply() } }
/// }
/// ```
@MainActor
public final class DirtyObservations: InputResponseSource {
    /// The cause state the marks come from.
    public let causes: ObservationCauses
    private var entries: [Entry] = []

    public init(causes: ObservationCauses) {
        self.causes = causes
    }

    /// The observations waiting for a flush.
    public var count: Int { entries.count }

    /// Queues an observation that just became dirty, with the cause in effect now.
    ///
    /// - Parameter apply: Reads the model again (and so tracks it again) and applies it.
    public func markDirty(_ apply: @escaping @MainActor () -> Void) {
        entries.append(Entry(mark: causes.mark(), apply: apply))
    }

    /// Applies, in the order they became dirty, every queued observation whose flush class is
    /// `flushClass` now. One that becomes dirty again in an apply waits for the next call.
    ///
    /// - Returns: How many it applied.
    @discardableResult
    public func apply(_ flushClass: ObservationFlushClass) -> Int {
        var due: [Entry] = []
        entries.removeAll { entry in
            guard causes.flushClass(of: entry.mark) == flushClass else { return false }
            due.append(entry)
            return true
        }
        for entry in due { entry.apply() }
        return due.count
    }

    public func applyPersonCaused() -> Int {
        apply(.person)
    }

    private struct Entry {
        let mark: ObservationCauses.Mark
        let apply: @MainActor () -> Void
    }
}
