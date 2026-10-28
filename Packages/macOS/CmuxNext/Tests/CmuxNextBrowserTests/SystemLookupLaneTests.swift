import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextRemoteFetch
import CmuxNextWakeups
import Foundation
import Testing

/// Host lookups run on the app's host-resolution slots of the system lane (plans/cmux-next/chrome-parity/p02-threads.md,
/// task 059), never on the cooperative pool or main: the omnibar's intranet check at user-blocking (a person is typing),
/// the guarded page fetch's one lookup at user-visible. A fetcher built before the app wires its resolver fetches nothing.
/// `localhost` resolves from the hosts file, so no test here touches the network.
@Suite(.timeLimit(.minutes(1))) struct SystemLookupLaneTests {
    /// A ``MayBlockRunner`` over real lanes that records the priority of each host resolution and fails a test that
    /// resolves through the plain system lane.
    nonisolated struct RecordingRunner: MayBlockRunner {
        let lanes: BackgroundWork
        let record: AsyncStream<MayBlockPriority>.Continuation

        func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                   _ body: @escaping @Sendable () throws -> T) async throws -> T {
            try await lanes.runFiles(priority, shutdown: shutdown, site: site, body)
        }

        func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                    _ body: @escaping @Sendable () throws -> T) async throws -> T {
            Issue.record("a lookup ran on the system lane outside its host-resolution slots")
            return try await lanes.runSystem(priority, shutdown: shutdown, site: site, body)
        }

        func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                            _ body: @escaping @Sendable () throws -> T) async throws -> T {
            record.yield(priority)
            return try await lanes.runHostResolution(priority, shutdown: shutdown, site: site, body)
        }

        func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                       _ body: @escaping @Sendable () -> Void) {
            lanes.postFiles(priority, shutdown: shutdown, site: site, body)
        }
    }

    /// The priorities recorded once `record` finished.
    static func recorded(_ stream: AsyncStream<MayBlockPriority>) async -> [MayBlockPriority] {
        var seen: [MayBlockPriority] = []
        for await priority in stream { seen.append(priority) }
        return seen
    }

    @Test func theIntranetCheckResolvesOnTheHostResolutionSlotsAtUserBlocking() async {
        let (priorities, record) = AsyncStream.makeStream(of: MayBlockPriority.self)
        let lookup = SystemHostLookup(runner: RecordingRunner(lanes: BackgroundWork(label: "test.intranet"), record: record))
        #expect(await lookup.resolves("localhost"))
        record.finish()
        #expect(await Self.recorded(priorities) == [.userBlocking])
    }

    @Test func thePageFetchResolvesOnTheHostResolutionSlotsAtUserVisible() async throws {
        let (priorities, record) = AsyncStream.makeStream(of: MayBlockPriority.self)
        let resolver = SystemRemoteResolver(runner: RecordingRunner(lanes: BackgroundWork(label: "test.remote"), record: record))
        let addresses = try await resolver.resolve("localhost")
        record.finish()
        #expect(!addresses.isEmpty)
        #expect(addresses.allSatisfy { !$0.isPublic }, "localhost resolved to \(addresses)")
        #expect(await Self.recorded(priorities) == [.userVisible])
    }

    /// Addresses keep network byte order, whether parsed from a literal or copied out of a lookup's sockaddr.
    @Test func addressesKeepNetworkByteOrder() async throws {
        #expect(RemoteAddress(literal: "203.0.113.7") == .v4([203, 0, 113, 7]))
        #expect(RemoteAddress(literal: "2001:db8::1") == .v6([0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1]))
        #expect(RemoteAddress(literal: "::ffff:10.1.2.3") == .v6([UInt8](repeating: 0, count: 10) + [0xff, 0xff, 10, 1, 2, 3]))
        #expect(RemoteAddress(literal: "fe80::1%en0") == nil)
        #expect(RemoteAddress(literal: "example.com") == nil)
        let (_, record) = AsyncStream.makeStream(of: MayBlockPriority.self)
        let resolver = SystemRemoteResolver(runner: RecordingRunner(lanes: BackgroundWork(label: "test.order"), record: record))
        let addresses = try await resolver.resolve("127.0.0.1")
        record.finish()
        #expect(addresses == [.v4([127, 0, 0, 1])])
    }

    @Test func anUnwiredResolverFindsNoHost() async {
        await #expect(throws: URLError.self) { try await UnwiredRemoteResolver().resolve("localhost") }
    }
}
