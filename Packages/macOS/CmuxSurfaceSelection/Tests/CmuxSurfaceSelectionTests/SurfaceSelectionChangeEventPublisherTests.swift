import Foundation
import Testing
@testable import CmuxSurfaceSelection

@Suite(.serialized)
@MainActor
struct SurfaceSelectionChangeEventPublisherTests {
    private final class Sink: SurfaceSelectionEventSink {
        var optedIn = true
        var published: [(SurfaceSelectionEventIdentity, SurfaceSelectionEventSnapshot)] = []

        func hasOptInSubscriber() -> Bool { optedIn }

        @discardableResult
        func publish(
            identity: SurfaceSelectionEventIdentity,
            snapshot: SurfaceSelectionEventSnapshot
        ) -> Bool {
            published.append((identity, snapshot))
            return true
        }
    }

    private final class ManualScheduler: SurfaceSelectionDebounceScheduling {
        var action: (@MainActor () -> Void)?

        func schedule(after _: Duration, _ action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        func cancel() {
            action = nil
        }

        func fire() {
            let action = action
            self.action = nil
            action?()
        }
    }

    private final class Source {}

    private func identity(surfaceId: UUID) -> SurfaceSelectionEventIdentity {
        SurfaceSelectionEventIdentity(
            workspaceId: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            workspaceRef: "workspace:1",
            surfaceId: surfaceId,
            surfaceRef: "surface:1"
        )
    }

    @Test
    func coalescesSignalsAndReleasesPendingSource() {
        let sink = Sink()
        let scheduler = ManualScheduler()
        let publisher = SurfaceSelectionChangeEventPublisher(
            sink: sink,
            schedulerFactory: { scheduler }
        )
        let surfaceId = UUID()
        let source = Source()
        publisher.registerSnapshotSource(
            surfaceId: surfaceId,
            sourceIdentity: ObjectIdentifier(source),
            owner: source,
            identity: { self.identity(surfaceId: surfaceId) }
        )

        publisher.signal(surfaceId: surfaceId, snapshot: .selected(kind: "markdown", text: "first"))
        publisher.signal(surfaceId: surfaceId, snapshot: .selected(kind: "markdown", text: "last"))
        #expect(sink.published.isEmpty)
        scheduler.fire()

        #expect(sink.published.count == 1)
        #expect(sink.published.first?.1.text == "last")
        publisher.unregister(surfaceId: surfaceId)
        #expect(!publisher.hasRegistration(for: surfaceId))
    }

    @Test
    func lateTeardownCannotRemoveReplacementSource() {
        let sink = Sink()
        let scheduler = ManualScheduler()
        let publisher = SurfaceSelectionChangeEventPublisher(
            sink: sink,
            schedulerFactory: { scheduler }
        )
        let surfaceId = UUID()
        let first = Source()
        let second = Source()
        publisher.registerSnapshotSource(
            surfaceId: surfaceId,
            sourceIdentity: ObjectIdentifier(first),
            owner: first,
            identity: { self.identity(surfaceId: surfaceId) }
        )
        publisher.registerSnapshotSource(
            surfaceId: surfaceId,
            sourceIdentity: ObjectIdentifier(second),
            owner: second,
            identity: { self.identity(surfaceId: surfaceId) }
        )

        publisher.unregister(
            surfaceId: surfaceId,
            ifSourceIdentity: ObjectIdentifier(first)
        )
        #expect(publisher.hasRegistration(for: surfaceId))
        publisher.signal(surfaceId: surfaceId, snapshot: .selected(kind: "browser", text: "current"))
        scheduler.fire()
        #expect(sink.published.last?.1.text == "current")
    }

    @Test
    func optOutDropsSignalsBeforeTheyReachTheSink() {
        let sink = Sink()
        sink.optedIn = false
        let scheduler = ManualScheduler()
        let publisher = SurfaceSelectionChangeEventPublisher(
            sink: sink,
            schedulerFactory: { scheduler }
        )
        let surfaceId = UUID()
        let source = Source()
        publisher.registerSnapshotSource(
            surfaceId: surfaceId,
            sourceIdentity: ObjectIdentifier(source),
            owner: source,
            identity: { self.identity(surfaceId: surfaceId) }
        )

        publisher.signal(surfaceId: surfaceId, snapshot: .selected(kind: "terminal", text: "private"))
        scheduler.fire()
        #expect(sink.published.isEmpty)
    }

    @Test
    func signalAcceptsNewestReplacementAndCoalescesBeforeConsumption() async {
        let signal = TerminalSelectionChangeSignal()
        #expect(signal.request())
        #expect(signal.request())
        signal.finish()

        var yieldedCount = 0
        for await _ in signal.events {
            yieldedCount += 1
        }
        #expect(yieldedCount == 1)
    }
}
