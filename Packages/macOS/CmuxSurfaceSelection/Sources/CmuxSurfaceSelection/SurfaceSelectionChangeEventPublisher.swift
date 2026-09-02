public import Foundation

/// Owns per-surface coalescing and teardown for selection events.
///
/// The publisher knows nothing about AppKit, WebKit, or the application's event
/// bus. Owners provide source signals and an injected sink, which keeps the
/// contract independently testable and makes source replacement explicit.
@MainActor
public final class SurfaceSelectionChangeEventPublisher {
    /// Supplies the current event identity for a registered source.
    public typealias IdentityProvider = @MainActor () -> SurfaceSelectionEventIdentity?
    /// Reads a source's current selection when a debounce deadline fires.
    public typealias SnapshotReader = @MainActor () -> SurfaceSelectionEventSnapshot?
    /// Creates a cancellation-aware deadline scheduler for one source.
    public typealias SchedulerFactory = @MainActor () -> any SurfaceSelectionDebounceScheduling

    @MainActor
    private final class Entry {
        let surfaceId: UUID
        let sourceIdentity: ObjectIdentifier?
        let identity: IdentityProvider
        let reader: SnapshotReader?
        let scheduler: any SurfaceSelectionDebounceScheduling
        let onCancel: (@MainActor () -> Void)?
        var sourceOwner: AnyObject?
        var eventsTask: Task<Void, Never>?
        var generation: UInt64 = 0
        var pendingSnapshot: SurfaceSelectionEventSnapshot?
        var pendingIdentity: SurfaceSelectionEventIdentity?
        var lastIdentity: SurfaceSelectionEventIdentity?
        var lastSnapshot: SurfaceSelectionEventSnapshot?

        init(
            surfaceId: UUID,
            sourceIdentity: ObjectIdentifier?,
            identity: @escaping IdentityProvider,
            reader: SnapshotReader?,
            owner: AnyObject?,
            scheduler: any SurfaceSelectionDebounceScheduling,
            onCancel: (@MainActor () -> Void)?
        ) {
            self.surfaceId = surfaceId
            self.sourceIdentity = sourceIdentity
            self.identity = identity
            self.reader = reader
            self.sourceOwner = owner
            self.scheduler = scheduler
            self.onCancel = onCancel
        }

        func cancel() {
            eventsTask?.cancel()
            eventsTask = nil
            scheduler.cancel()
            pendingSnapshot = nil
            pendingIdentity = nil
            onCancel?()
            sourceOwner = nil
        }
    }

    private let sink: any SurfaceSelectionEventSink
    private let debounceDuration: Duration
    private let schedulerFactory: SchedulerFactory
    private var entries: [UUID: Entry] = [:]

    /// Creates a publisher with an injected event sink and deadline source.
    ///
    /// - Parameters:
    ///   - sink: The owner that knows whether the protected topic is opted in
    ///     and publishes accepted snapshots.
    ///   - debounceNanoseconds: The bounded coalescing window.
    ///   - schedulerFactory: A cancellation-aware scheduler factory. Tests can
    ///     inject a deterministic scheduler; production uses one timer per
    ///     registered surface.
    public init(
        sink: any SurfaceSelectionEventSink,
        debounceNanoseconds: UInt64 = 100_000_000,
        schedulerFactory: @escaping SchedulerFactory = { SurfaceSelectionDispatchTimerScheduler() }
    ) {
        self.sink = sink
        self.debounceDuration = .nanoseconds(Int64(clamping: debounceNanoseconds))
        self.schedulerFactory = schedulerFactory
    }

    /// Registers a signal source. Re-registering the same object is idempotent.
    public func register(
        surfaceId: UUID,
        sourceIdentity: ObjectIdentifier? = nil,
        owner: AnyObject? = nil,
        events: AsyncStream<Void>? = nil,
        identity: @escaping IdentityProvider,
        reader: @escaping SnapshotReader,
        onCancel: (@MainActor () -> Void)? = nil
    ) {
        if let existing = entries[surfaceId],
           existing.sourceIdentity == sourceIdentity,
           sourceIdentity != nil {
            return
        }
        installEntry(
            Entry(
                surfaceId: surfaceId,
                sourceIdentity: sourceIdentity,
                identity: identity,
                reader: reader,
                owner: owner,
                scheduler: schedulerFactory(),
                onCancel: onCancel
            ),
            events: events
        )
    }

    /// Registers a source that supplies an immutable snapshot with each signal.
    public func registerSnapshotSource(
        surfaceId: UUID,
        sourceIdentity: ObjectIdentifier,
        owner: AnyObject? = nil,
        identity: @escaping IdentityProvider
    ) {
        if let existing = entries[surfaceId], existing.sourceIdentity == sourceIdentity {
            return
        }
        installEntry(
            Entry(
                surfaceId: surfaceId,
                sourceIdentity: sourceIdentity,
                identity: identity,
                reader: nil,
                owner: owner,
                scheduler: schedulerFactory(),
                onCancel: nil
            ),
            events: nil
        )
    }

    /// Signals a source whose current snapshot is read at the deadline.
    public func signal(surfaceId: UUID) {
        signal(surfaceId: surfaceId, snapshot: nil)
    }

    /// Signals a source with an immutable snapshot captured at the source edge.
    public func signal(surfaceId: UUID, snapshot: SurfaceSelectionEventSnapshot) {
        signal(surfaceId: surfaceId, snapshot: Optional(snapshot))
    }

    /// Removes a source and cancels its pending deadline.
    public func unregister(surfaceId: UUID) {
        guard let entry = entries.removeValue(forKey: surfaceId) else { return }
        entry.cancel()
    }

    /// Removes a source only when it still belongs to `sourceIdentity`.
    ///
    /// This protects a replacement source (for example a native editor) from
    /// a late WebKit teardown callback.
    public func unregister(surfaceId: UUID, ifSourceIdentity sourceIdentity: ObjectIdentifier) {
        guard entries[surfaceId]?.sourceIdentity == sourceIdentity else { return }
        unregister(surfaceId: surfaceId)
    }

    /// Cancels an in-flight emission without detaching the source.
    public func cancelPending(surfaceId: UUID, resetLastSnapshot: Bool = true) {
        guard let entry = entries[surfaceId] else { return }
        entry.generation &+= 1
        entry.scheduler.cancel()
        entry.pendingSnapshot = nil
        entry.pendingIdentity = nil
        if resetLastSnapshot {
            entry.lastIdentity = nil
            entry.lastSnapshot = nil
        }
    }

    /// Whether a source is currently registered for `surfaceId`.
    public func hasRegistration(for surfaceId: UUID) -> Bool {
        entries[surfaceId] != nil
    }

    /// Whether the sink currently has an explicit subscriber.
    public func hasOptInSubscriber() -> Bool {
        sink.hasOptInSubscriber()
    }

    private func installEntry(_ entry: Entry, events: AsyncStream<Void>?) {
        entries[entry.surfaceId]?.cancel()
        entries[entry.surfaceId] = entry
        guard let events else { return }
        let surfaceId = entry.surfaceId
        let sourceIdentity = entry.sourceIdentity
        entry.eventsTask = Task { @MainActor [weak self, events] in
            for await _ in events {
                guard !Task.isCancelled else { return }
                self?.signal(surfaceId: surfaceId)
            }
            guard !Task.isCancelled else { return }
            guard let self,
                  self.entries[surfaceId]?.sourceIdentity == sourceIdentity else { return }
            self.unregister(surfaceId: surfaceId)
        }
    }

    /// Schedules one cancellation-aware coalescing deadline.
    private func signal(surfaceId: UUID, snapshot: SurfaceSelectionEventSnapshot?) {
        guard let entry = entries[surfaceId], sink.hasOptInSubscriber() else {
            return
        }
        entry.pendingSnapshot = snapshot
        if entry.pendingIdentity == nil {
            entry.pendingIdentity = entry.identity()
        }
        entry.generation &+= 1
        let generation = entry.generation
        entry.scheduler.schedule(after: debounceDuration) { [weak self, weak entry] in
            guard let self, let entry,
                  let currentEntry = self.entries[surfaceId],
                  currentEntry === entry,
                  currentEntry.generation == generation else { return }
            self.emit(surfaceId: surfaceId, generation: generation)
        }
    }

    private func emit(surfaceId: UUID, generation: UInt64) {
        guard let entry = entries[surfaceId],
              entry.generation == generation,
              sink.hasOptInSubscriber(),
              let identity = entry.identity(),
              let pendingIdentity = entry.pendingIdentity,
              identity == pendingIdentity else {
            if let entry = entries[surfaceId], entry.generation == generation {
                entry.pendingSnapshot = nil
                entry.pendingIdentity = nil
                entry.lastIdentity = nil
                entry.lastSnapshot = nil
            }
            return
        }

        let snapshot = entry.pendingSnapshot ?? entry.reader?()
        entry.pendingSnapshot = nil
        entry.pendingIdentity = nil
        guard let snapshot else { return }
        guard entry.lastIdentity != identity || entry.lastSnapshot != snapshot else { return }

        let published = sink.publish(identity: identity, snapshot: snapshot)
        guard published else { return }
        entry.lastIdentity = identity
        entry.lastSnapshot = snapshot
    }
}
