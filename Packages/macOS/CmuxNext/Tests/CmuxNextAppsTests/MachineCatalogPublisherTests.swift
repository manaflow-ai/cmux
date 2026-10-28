import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextWakeups
import Observation
import Foundation
import Testing
@testable import CmuxNextApps

@MainActor
struct MachineCatalogPublisherTests {
    private let owner: ResourceID = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let other: ResourceID = "machine_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    /// A scheduler of its own per test: the registry follow's flushes post on it (automation runs on the next turn).
    static func work() -> MainWorkScheduler { MainWorkScheduler(budget: MainFrameBudget()) }

    private func record() -> MachineCatalogRecord {
        MachineCatalogRecord(id: other, name: "server", origin: .ssh, status: .running,
                             platform: .init(os: "linux", arch: "aarch64"), capabilities: ["terminal"])!
    }

    @Test func observedRoutesPublishAndRemovalWithdrawsWithoutPolling() async throws {
        let writer = CatalogTestWriter()
        var events = writer.attempts.makeAsyncIterator()
        let registry = CatalogTestRegistry(MachineCatalogSource(owner: owner, writer: writer, epoch: 1, machines: [record()]))
        let publisher = MachineCatalogPublisher(source: { registry.value }, on: Self.work())
        defer { publisher.stop() }
        publisher.start()
        let first = try #require(await events.next())
        #expect(first.expectedMachineID == owner && first.sequence == 1)
        #expect(first.machines.map(\.id) == [other])
        await publisher.sending?.value
        registry.value = MachineCatalogSource(owner: owner, writer: writer, epoch: 1, machines: [])
        let removed = try #require(await events.next())
        #expect(removed.sequence == 2 && removed.machines.isEmpty)
        await publisher.sending?.value
        #expect(publisher.publishedSequence == 2)
        #expect(await writer.requests.count == 2)
    }

    @Test func handoffRepublishesUnchangedRecordsOnTheNewEpoch() async throws {
        let writer = CatalogTestWriter()
        var events = writer.attempts.makeAsyncIterator()
        let registry = CatalogTestRegistry(MachineCatalogSource(owner: owner, writer: writer, epoch: 1, machines: [record()]))
        let publisher = MachineCatalogPublisher(source: { registry.value }, on: Self.work())
        defer { publisher.stop() }
        publisher.start()
        _ = try #require(await events.next())
        await publisher.sending?.value
        registry.value = MachineCatalogSource(owner: owner, writer: writer, epoch: 2, machines: [record()])
        let newLease = try #require(await events.next())
        #expect(newLease.sequence == 1 && newLease.machines == [record()])
        await publisher.sending?.value
        #expect(await writer.requests.count == 2)
    }

    @Test func stopAndRestartDoNotReuseALiveLeasesSequence() async throws {
        let writer = CatalogTestWriter()
        var events = writer.attempts.makeAsyncIterator()
        let registry = CatalogTestRegistry(MachineCatalogSource(owner: owner, writer: writer, epoch: 1, machines: []))
        let publisher = MachineCatalogPublisher(source: { registry.value }, on: Self.work())
        defer { publisher.stop() }
        publisher.start()
        #expect(try #require(await events.next()).sequence == 1)
        await publisher.sending?.value
        publisher.stop()
        publisher.start()
        #expect(try #require(await events.next()).sequence == 2)
        await publisher.sending?.value
    }

    @Test func temporarySourceLossDoesNotReuseALiveLeasesSequence() async throws {
        let writer = CatalogTestWriter()
        var events = writer.attempts.makeAsyncIterator()
        let value = MachineCatalogSource(owner: owner, writer: writer, epoch: 1, machines: [])
        let registry = CatalogTestRegistry(value)
        let publisher = MachineCatalogPublisher(source: { registry.value }, on: Self.work())
        defer { publisher.stop() }
        publisher.start()
        _ = try #require(await events.next())
        await publisher.sending?.value
        let withdrawn = Task { @MainActor in
            for await value in ObservationStream({ publisher.current }) { if value == nil { return } }
        }
        registry.value = nil
        await withdrawn.value
        registry.value = value
        #expect(try #require(await events.next()).sequence == 2)
        await publisher.sending?.value
    }

    @Test func aLateOldOwnerAcknowledgementCannotReplaceTheNewReceipt() async throws {
        let gate = CatalogAcknowledgementGate()
        let old = CatalogTestWriter(pause: { await gate.wait() })
        let fresh = CatalogTestWriter()
        var oldEvents = old.attempts.makeAsyncIterator()
        var newEvents = fresh.attempts.makeAsyncIterator()
        let registry = CatalogTestRegistry(MachineCatalogSource(owner: owner, writer: old, epoch: 1, machines: []))
        let publisher = MachineCatalogPublisher(source: { registry.value }, on: Self.work())
        defer { publisher.stop() }
        publisher.start()
        _ = try #require(await oldEvents.next())
        let oldAttempt = publisher.sending
        registry.value = MachineCatalogSource(owner: other, writer: fresh, epoch: 2, machines: [])
        let next = try #require(await newEvents.next())
        #expect(next.expectedMachineID == other && next.sequence == 1)
        await publisher.sending?.value
        await gate.release()
        await oldAttempt?.value
        #expect(publisher.publishedOwner == other)
        #expect(publisher.publishedSequence == 1)
    }

    @Test func revalidatesAdmissionBeforeTheFirstSend() async throws {
        let writer = CatalogTestWriter()
        let reads = AsyncStream<Int>.makeStream()
        var events = reads.stream.makeAsyncIterator()
        var count = 0
        let value = MachineCatalogSource(owner: owner, writer: writer, epoch: 1, machines: [record()])
        let publisher = MachineCatalogPublisher(source: {
            count += 1
            reads.continuation.yield(count)
            return count == 1 ? value : nil
        }, on: Self.work())
        defer { publisher.stop(); reads.continuation.finish() }
        publisher.start()
        while let count = await events.next() { if count >= 2 { break } }
        #expect(publisher.current == nil)
        #expect(await writer.requests.isEmpty)
    }

    @Test func aRealCompetingPublisherRefusalRetriesTheIdenticalSnapshot() async throws {
        let error = DaemonError.command(cmd: "machine-catalog-publish", message: "taken", code: "machine_catalog.taken", details: nil, retryable: nil)
        let writer = CatalogTestWriter(failures: [error, nil])
        var events = writer.attempts.makeAsyncIterator()
        let value = MachineCatalogSource(owner: owner, writer: writer, epoch: 1, machines: [record()])
        let publisher = MachineCatalogPublisher(source: { value }, on: Self.work(), backoff: .init(initial: .milliseconds(1), maximum: .milliseconds(1), jitter: 0))
        defer { publisher.stop() }
        publisher.start()
        let first = try #require(await events.next())
        let retry = try #require(await events.next())
        #expect(first.sequence == retry.sequence && first.machines == retry.machines)
        await publisher.sending?.value
        #expect(publisher.publishedSequence == 1)
    }

    @Test(arguments: [false, true])
    func permanentOwnerAndCapabilityRefusalsDoNotRetry(orMismatch: Bool) async throws {
        let error: DaemonError = orMismatch ? .command(cmd: "machine-catalog-publish", message: "wrong owner", code: "machine_catalog.owner_mismatch", details: nil, retryable: nil) : .missingCapabilities(["machine-catalog-publish-v1"])
        let writer = CatalogTestWriter(failures: [error])
        var events = writer.attempts.makeAsyncIterator()
        let value = MachineCatalogSource(owner: owner, writer: writer, epoch: 1, machines: [])
        let publisher = MachineCatalogPublisher(source: { value }, on: Self.work())
        defer { publisher.stop() }
        publisher.start()
        _ = try #require(await events.next())
        await publisher.sending?.value
        #expect(await writer.requests.count == 1)
        #expect(publisher.publishedSequence == nil)
    }

    @Test func sourceExcludesSelfAndEveryAmbiguousIdentity() throws {
        let writer = CatalogTestWriter()
        #expect(MachineCatalogSource(owner: "local", writer: writer, epoch: 1, machines: []) == nil)
        let own = try #require(MachineCatalogRecord(id: owner, name: "local alias", origin: .ssh, status: .running))
        let source = try #require(MachineCatalogSource(owner: owner, writer: writer, epoch: 1, machines: [own, record(), record()]))
        #expect(source.machines.isEmpty)
    }
    @Test func largeValidMetadataStillFitsTheNativeFrameBudget() throws {
        let writer = CatalogTestWriter()
        let capabilities = (0..<16).map { "cap" + String(repeating: "a", count: 60) + String($0, radix: 16) }
        let records = (1...256).compactMap { number in
            MachineCatalogRecord(id: ResourceID(rawValue: String(format: "machine_%032x", number)),
                name: String(repeating: "😀", count: 64), origin: .cloud, status: .running,
                platform: .init(os: String(repeating: "a", count: 64), arch: String(repeating: "b", count: 64)), capabilities: capabilities)
        }
        let source = try #require(MachineCatalogSource(owner: owner, writer: writer, epoch: 1, machines: records))
        #expect(!source.machines.isEmpty && source.machines.count < 256)
        let data = try WireCoding.encodeRequest(MachineCatalogPublishRequest(expectedMachineID: owner, sequence: .max, machines: source.machines), id: .max)
        #expect(data.count <= 128 * 1024)
    }

}
