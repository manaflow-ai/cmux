import CmuxSurfaceSelection

/// Adapts the application's event bus to the reusable selection publisher.
@MainActor
final class CmuxSurfaceSelectionEventSink: SurfaceSelectionEventSink {
    private let bus: CmuxEventBus

    init(bus: CmuxEventBus) {
        self.bus = bus
    }

    func hasOptInSubscriber() -> Bool {
        bus.hasExplicitSubscriber(for: CmuxEventBus.surfaceSelectionChangedEventName)
    }

    @discardableResult
    func publish(
        identity: SurfaceSelectionEventIdentity,
        snapshot: SurfaceSelectionEventSnapshot
    ) -> Bool {
        bus.publishSurfaceSelectionChanged(identity: identity, snapshot: snapshot)
    }
}

/// Preserves the app-target construction convenience used by panel code and
/// existing contract tests while the implementation lives in SwiftPM.
@MainActor
extension SurfaceSelectionChangeEventPublisher {
    convenience init(
        bus: CmuxEventBus = .shared,
        debounceNanoseconds: UInt64 = 100_000_000
    ) {
        self.init(
            sink: CmuxSurfaceSelectionEventSink(bus: bus),
            debounceNanoseconds: debounceNanoseconds
        )
    }
}
