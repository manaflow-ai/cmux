import CmuxSafeConcurrency
import Testing

/// The sites a sink under test was told about, in order.
private final class SiteLog: InvariantEventSink {
    private let events = Mutex<[InvariantEvent]>([])

    func deliver(_ event: InvariantEvent) {
        events.withLock { $0.append(event) }
    }

    var recorded: [InvariantEvent] {
        events.withLock { $0 }
    }
}

private final class Owner {}

/// A child's back-reference does not keep its owner alive, and a read after the owner is gone
/// reports instead of trapping (an `unowned` read traps there).
@Suite struct OwnerReferenceTests {
    @Test func aLiveOwnerResolvesAndReportsNothing() {
        let invariant = Invariant(capacity: 8)
        let log = SiteLog()
        invariant.install(build: 10, sink: log)
        let owner = Owner()
        let reference = OwnerReference(owner, invariant: "owner-outlives-child")
        #expect(reference.resolve(in: invariant) === owner)
        #expect(log.recorded.isEmpty)
    }

    @Test func theReferenceDoesNotKeepItsOwner() {
        weak var released: Owner?
        let reference: OwnerReference<Owner> = {
            let owner = Owner()
            released = owner
            return OwnerReference(owner, invariant: "owner-outlives-child")
        }()
        #expect(released == nil, "a strong back-reference would keep the owner, a cycle when the owner holds the child")
        _ = reference
    }

    @Test func aReadAfterTheOwnerIsGoneReportsOncePerSiteAndReturnsNil() {
        let invariant = Invariant(capacity: 8)
        let log = SiteLog()
        invariant.install(build: 10, sink: log)
        let reference: OwnerReference<Owner> = OwnerReference(Owner(), invariant: "owner-outlives-child")
        for _ in 0 ..< 3 {
            #expect(reference.resolve(in: invariant) == nil)
        }
        #expect(log.recorded.count == 1)
        #expect(log.recorded.first?.id.description == "owner-outlives-child")
        #expect(log.recorded.first?.kind == .notFatalUntil(build: OwnerReference<Owner>.fatalFromBuild))
    }
}
