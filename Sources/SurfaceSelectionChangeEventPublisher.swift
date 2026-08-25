import AppKit
import Foundation

/// Owns debouncing, coalescing, and teardown for content-selection events.
/// Each entry is tied to one live surface source; there is no polling loop or
/// process-wide selection observer.
@MainActor
final class SurfaceSelectionChangeEventPublisher {
    static let shared = SurfaceSelectionChangeEventPublisher()

    typealias IdentityProvider = @MainActor () -> SurfaceSelectionEventIdentity?
    typealias SnapshotReader = @MainActor () -> SurfaceSelectionEventSnapshot?
    private final class Entry {
        let surfaceId: UUID
        let sourceIdentity: ObjectIdentifier?
        let identity: IdentityProvider
        let reader: SnapshotReader?
        let owner: AnyObject?
        var eventsTask: Task<Void, Never>?
        var debounceTimer: Timer?
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
            owner: AnyObject?
        ) {
            self.surfaceId = surfaceId
            self.sourceIdentity = sourceIdentity
            self.identity = identity
            self.reader = reader
            self.owner = owner
        }

        func cancel() {
            eventsTask?.cancel()
            debounceTimer?.invalidate()
            eventsTask = nil
            debounceTimer = nil
            pendingSnapshot = nil
            pendingIdentity = nil
            if let observer = owner as? SurfaceSelectionNativeObserver {
                observer.stop()
            }
        }
    }

    private let bus: CmuxEventBus
    private let debounceNanoseconds: UInt64
    private var entries: [UUID: Entry] = [:]

    init(
        bus: CmuxEventBus = .shared,
        debounceNanoseconds: UInt64 = 100_000_000
    ) {
        self.bus = bus
        self.debounceNanoseconds = debounceNanoseconds
    }

    /// Registers a signal whose reader is sampled after the debounce window.
    /// Re-registering the same source is idempotent, which matters when a
    /// SwiftUI representable is updated without replacing its native view.
    func register(
        surfaceId: UUID,
        sourceIdentity: ObjectIdentifier? = nil,
        owner: AnyObject? = nil,
        events: AsyncStream<Void>,
        identity: @escaping IdentityProvider,
        reader: @escaping SnapshotReader
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
                owner: owner
            ),
            events: events
        )
    }

    /// Registers a source that supplies an immutable snapshot with each
    /// signal (the WebKit bridge uses this path).
    func registerSnapshotSource(
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
                owner: owner
            ),
            events: nil
        )
    }

    func registerNativeTextSource(
        surfaceId: UUID,
        textView: NSTextView,
        identity: @escaping IdentityProvider,
        reader: @escaping SnapshotReader
    ) {
        if let existing = entries[surfaceId],
           existing.sourceIdentity == ObjectIdentifier(textView) {
            return
        }
        unregister(surfaceId: surfaceId)
        let observer = SurfaceSelectionNativeObserver(textView: textView) { [weak self] in
            self?.signal(surfaceId: surfaceId)
        }
        installEntry(
            Entry(
                surfaceId: surfaceId,
                sourceIdentity: ObjectIdentifier(textView),
                identity: identity,
                reader: reader,
                owner: observer
            ),
            events: nil
        )
    }

    func signal(surfaceId: UUID) {
        signal(surfaceId: surfaceId, snapshot: nil)
    }

    func signal(surfaceId: UUID, snapshot: SurfaceSelectionEventSnapshot) {
        signal(surfaceId: surfaceId, snapshot: Optional(snapshot))
    }

    func unregister(surfaceId: UUID) {
        guard let entry = entries.removeValue(forKey: surfaceId) else { return }
        entry.cancel()
    }

    private func unregisterIfCurrent(surfaceId: UUID, sourceIdentity: ObjectIdentifier?) {
        guard let entry = entries[surfaceId], entry.sourceIdentity == sourceIdentity else { return }
        unregister(surfaceId: surfaceId)
    }

    /// Cancels an in-flight document emission without detaching the source.
    /// WebKit uses this at document replacement so a selection from the old
    /// page cannot cross the navigation boundary.
    func cancelPending(surfaceId: UUID, resetLastSnapshot: Bool = true) {
        guard let entry = entries[surfaceId] else { return }
        entry.generation &+= 1
        entry.debounceTimer?.invalidate()
        entry.debounceTimer = nil
        entry.pendingSnapshot = nil
        entry.pendingIdentity = nil
        if resetLastSnapshot {
            entry.lastIdentity = nil
            entry.lastSnapshot = nil
        }
    }

    func hasRegistration(for surfaceId: UUID) -> Bool {
        entries[surfaceId] != nil
    }

    func hasOptInSubscriber() -> Bool {
        bus.hasExplicitSubscriber(for: CmuxEventBus.surfaceSelectionChangedEventName)
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
            self?.unregisterIfCurrent(surfaceId: surfaceId, sourceIdentity: sourceIdentity)
        }
    }

    private func signal(surfaceId: UUID, snapshot: SurfaceSelectionEventSnapshot?) {
        guard let entry = entries[surfaceId],
              bus.hasExplicitSubscriber(for: CmuxEventBus.surfaceSelectionChangedEventName) else {
            return
        }
        entry.pendingSnapshot = snapshot
        if entry.pendingIdentity == nil {
            entry.pendingIdentity = entry.identity()
        }
        entry.generation &+= 1
        let generation = entry.generation
        entry.debounceTimer?.invalidate()
        let timer = Timer(
            timeInterval: Double(self.debounceNanoseconds) / 1_000_000_000,
            repeats: false
        ) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self,
                      let entry = self.entries[surfaceId],
                      entry.debounceTimer === timer else { return }
                entry.debounceTimer = nil
                self.emit(surfaceId: surfaceId, generation: generation)
            }
        }
        entry.debounceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func emit(surfaceId: UUID, generation: UInt64) {
        guard let entry = entries[surfaceId],
              entry.generation == generation,
              bus.hasExplicitSubscriber(for: CmuxEventBus.surfaceSelectionChangedEventName),
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

        let published = bus.publishSurfaceSelectionChanged(
            identity: identity,
            snapshot: snapshot
        )
        guard published else { return }
        entry.lastIdentity = identity
        entry.lastSnapshot = snapshot
    }

    deinit {
        entries.values.forEach { $0.cancel() }
    }
}
