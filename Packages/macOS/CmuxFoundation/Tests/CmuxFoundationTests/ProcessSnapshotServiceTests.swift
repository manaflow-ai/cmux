import Testing
@testable import CmuxFoundation

struct ProcessSnapshotServiceTests {
    typealias Fields = ProcessSnapshotTestProvider.Fields
    typealias Service = ProcessSnapshotService<ProcessSnapshotTestProvider.Value, Fields>

    @Test func overlappingRequestsShareBaseAndEnrichment() async throws {
        let provider = ProcessSnapshotTestProvider()
        let clock = ProcessSnapshotTestClock()
        let service = Service(now: clock.now, capture: { await provider.capture() }, enrich: { await provider.enrich($0, fields: $1) })
        let first = Task { try await service.snapshot(fields: [.scope, .paths], freshness: .maximumAge(.seconds(5))) }
        await provider.waitForCapture(1)
        let peers = (0..<7).map { _ in
            Task { try await service.snapshot(fields: [.scope, .paths], freshness: .maximumAge(.seconds(5))) }
        }
        await clock.waitForRead(8)
        await provider.release()
        let value = try await first.value
        for peer in peers { #expect(try await peer.value === value) }
        #expect(await provider.captures == 1)
        #expect(await provider.enrichments == [[.scope, .paths]])
        #expect(await provider.maximumActive == 1)
    }

    @Test func richerRequestEnrichesWithoutRecensus() async throws {
        let provider = ProcessSnapshotTestProvider()
        await provider.release()
        let service = Service(capture: { await provider.capture() }, enrich: { await provider.enrich($0, fields: $1) })
        let base = try await service.snapshot(fields: [], freshness: .afterRequest)
        #expect(await provider.enrichments.isEmpty)
        let rich = try await service.snapshot(fields: .paths, freshness: .maximumAge(.seconds(5)))
        let scoped = try await service.snapshot(fields: [.paths, .scope], freshness: .maximumAge(.seconds(5)))
        #expect(base.generation == rich.generation && rich.generation == scoped.generation)
        #expect(await provider.captures == 1)
        #expect(await provider.enrichments == [.paths, .scope])
    }

    @Test func freshRequestWaitsForSuccessorEvenDuringAnActiveCensus() async throws {
        let provider = ProcessSnapshotTestProvider()
        let clock = ProcessSnapshotTestClock()
        let service = Service(now: clock.now, capture: { await provider.capture() }, enrich: { await provider.enrich($0, fields: $1) })
        let old = Task { try await service.snapshot(fields: [], freshness: .afterRequest) }
        await provider.waitForCapture(1)
        let fresh = Task { try await service.snapshot(fields: [], freshness: .afterRequest) }
        await clock.waitForRead(2)
        await provider.release(remaining: true)
        await provider.waitForCapture(2)
        await provider.release()
        #expect(try await old.value.generation == 1)
        #expect(try await fresh.value.generation == 2)
        #expect(await provider.maximumActive == 1)
    }

    @Test func ageIncludesCaptureDurationAndExpiryNeverReturnsAStaleValue() async throws {
        let provider = ProcessSnapshotTestProvider()
        let clock = ProcessSnapshotTestClock()
        let service = Service(now: clock.now, capture: { await provider.capture() }, enrich: { await provider.enrich($0, fields: $1) })
        let first = Task { try await service.snapshot(fields: [], freshness: .maximumAge(.seconds(2))) }
        await provider.waitForCapture(1)
        clock.advance(.seconds(3))
        await provider.release()
        await #expect(throws: ProcessSnapshotError.self) { try await first.value }
        let next = try await service.snapshot(fields: [], freshness: .maximumAge(.seconds(2)))
        #expect(next.generation == 2)
    }

    @Test func cancelledPeerDoesNotCancelSurvivor() async throws {
        let provider = ProcessSnapshotTestProvider()
        let clock = ProcessSnapshotTestClock()
        let service = Service(now: clock.now, capture: { await provider.capture() }, enrich: { await provider.enrich($0, fields: $1) })
        let survivor = Task { try await service.snapshot(fields: [], freshness: .maximumAge(.seconds(5))) }
        await provider.waitForCapture(1)
        let cancelled = Task { try await service.snapshot(fields: .paths, freshness: .maximumAge(.seconds(5))) }
        await clock.waitForRead(2)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await provider.release()
        #expect(try await survivor.value.generation == 1)
        #expect(await provider.captures == 1)
        #expect(await provider.enrichments.isEmpty)
    }

    @Test func allCancelledWorkKeepsOwnershipUntilItsProviderReturns() async throws {
        let provider = ProcessSnapshotTestProvider()
        let clock = ProcessSnapshotTestClock()
        let service = Service(now: clock.now, capture: { await provider.capture() }, enrich: { await provider.enrich($0, fields: $1) })
        let cancelled = Task { try await service.snapshot(fields: [], freshness: .afterRequest) }
        await provider.waitForCapture(1)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let successor = Task { try await service.snapshot(fields: [], freshness: .afterRequest) }
        await clock.waitForRead(2)
        #expect(await provider.captures == 1)
        await provider.release(remaining: true)
        await provider.waitForCapture(2)
        await provider.release()
        #expect(try await successor.value.generation == 2)
        #expect(await provider.maximumActive == 1)
    }
    @Test func enrichmentCannotResetTheCensusAge() async throws {
        let provider = ProcessSnapshotTestProvider()
        await provider.release()
        let clock = ProcessSnapshotTestClock()
        let service = Service(
            now: clock.now, capture: { await provider.capture() },
            enrich: { value, fields in
                clock.advance(.seconds(3))
                return await provider.enrich(value, fields: fields)
            }
        )
        await #expect(throws: ProcessSnapshotError.self) {
            try await service.snapshot(fields: .paths, freshness: .maximumAge(.seconds(2)))
        }
        #expect(await provider.captures == 1)
    }

    @Test func scopeInstancesNeverShareAndSuccessorReleasesTheOldValue() async throws {
        let provider = ProcessSnapshotTestProvider()
        await provider.release()
        let firstScope = Service(capture: { await provider.capture() }, enrich: { await provider.enrich($0, fields: $1) })
        let secondScope = Service(capture: { await provider.capture() }, enrich: { await provider.enrich($0, fields: $1) })
        var old: ProcessSnapshotTestValue? = try await firstScope.snapshot(fields: [], freshness: .afterRequest)
        weak var retained = old
        old = nil
        #expect(retained != nil)
        _ = try await firstScope.snapshot(fields: [], freshness: .afterRequest)
        #expect(retained == nil)
        _ = try await secondScope.snapshot(fields: [], freshness: .maximumAge(.seconds(5)))
        #expect(await provider.captures == 3)
    }

}
