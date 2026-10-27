import Foundation
import Testing
@testable import CmuxMobileShell
import CmuxMobileSSH

@MainActor
@Suite struct MobileSSHCmuxTUITopologyReconnectTests {
    actor Gate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var signaled = false

        func wait() async {
            if signaled {
                signaled = false
                return
            }
            await withCheckedContinuation { continuation in
                waiting = continuation
            }
        }

        func signal() {
            if let waiting {
                self.waiting = nil
                waiting.resume()
            } else {
                signaled = true
            }
        }
    }

    @MainActor
    final class FakeControl: Sendable {
        let id: Int
        let stream: AsyncStream<CmuxTUIControlEvent>
        let continuation: AsyncStream<CmuxTUIControlEvent>.Continuation
        private(set) var isClosed = false

        init(id: Int) {
            self.id = id
            (stream, continuation) = AsyncStream<CmuxTUIControlEvent>.makeStream()
        }

        func close() {
            isClosed = true
            continuation.finish()
        }
    }

    @Test func transientDisconnectReopensControlAndForwardsLaterTopology() async throws {
        let first = FakeControl(id: 1)
        let second = FakeControl(id: 2)
        var pending = [first, second]
        var openCount = 0
        let (connections, connectionContinuation) = AsyncStream<(UInt64, Bool)>.makeStream()
        let (events, eventContinuation) = AsyncStream<(CmuxTUIControlEvent, UInt64)>.makeStream()
        let reconnect = MobileSSHCmuxTUITopologyReconnect<FakeControl>(
            open: {
                openCount += 1
                return pending.removeFirst()
            },
            subscribe: { $0.stream },
            close: { $0.close() },
            transportIsOpen: { true },
            sleep: { duration in try await ContinuousClock().sleep(for: duration) },
            onEvent: { event, generation in eventContinuation.yield((event, generation)) },
            onTransportGap: { _ in },
            onControlConnected: { generation, recovered in connectionContinuation.yield((generation, recovered)) }
        )
        var connectionIterator = connections.makeAsyncIterator()
        var eventIterator = events.makeAsyncIterator()

        _ = try await reconnect.connect()
        #expect(await connectionIterator.next()?.1 == false)

        first.continuation.yield(.disconnected)
        #expect(await eventIterator.next()?.0 == .disconnected)
        #expect(await connectionIterator.next()?.1 == true)
        #expect(openCount == 2)
        #expect(first.isClosed)
        #expect(!second.isClosed)

        second.continuation.yield(.treeChanged)
        #expect(await eventIterator.next()?.0 == .treeChanged)
        await reconnect.close()
    }

    @Test func subscriptionFailureBacksOffBeforeReplacingControl() async throws {
        let first = FakeControl(id: 1)
        let second = FakeControl(id: 2)
        let third = FakeControl(id: 3)
        var pending = [first, second, third]
        var openCount = 0
        var delays: [Duration] = []
        let (connections, connectionContinuation) = AsyncStream<(UInt64, Bool)>.makeStream()
        let reconnect = MobileSSHCmuxTUITopologyReconnect<FakeControl>(
            open: {
                openCount += 1
                return pending.removeFirst()
            },
            subscribe: { control in
                if control.id == second.id { throw CmuxTUIError.closed }
                return control.stream
            },
            close: { control in control.close() },
            transportIsOpen: { true },
            sleep: { duration in delays.append(duration) },
            onEvent: { _, _ in },
            onTransportGap: { _ in },
            onControlConnected: { generation, recovered in connectionContinuation.yield((generation, recovered)) }
        )
        var connectionIterator = connections.makeAsyncIterator()

        _ = try await reconnect.connect()
        #expect(await connectionIterator.next()?.1 == false)

        first.continuation.yield(.disconnected)
        #expect(await connectionIterator.next()?.1 == true)
        #expect(await connectionIterator.next()?.1 == true)
        #expect(openCount == 3)
        #expect(delays == [.seconds(1)])
        await reconnect.close()
    }

    @Test func deadOwnerExhaustsRecoverySoDiscoveryCanDropProvider() async throws {
        let first = FakeControl(id: 1)
        var openCount = 0
        let (gaps, gapContinuation) = AsyncStream<UInt64>.makeStream()
        let reconnect = MobileSSHCmuxTUITopologyReconnect<FakeControl>(
            open: {
                openCount += 1
                if openCount == 1 { return first }
                throw CmuxTUIError.closed
            },
            subscribe: { $0.stream },
            close: { $0.close() },
            transportIsOpen: { true },
            sleep: { _ in },
            onEvent: { _, _ in },
            onTransportGap: { generation in gapContinuation.yield(generation) },
            onControlConnected: { _, _ in }
        )
        var gapIterator = gaps.makeAsyncIterator()

        _ = try await reconnect.connect()
        first.continuation.yield(.disconnected)
        #expect(await gapIterator.next() == 2)

        let result = Task { @MainActor in
            try? await reconnect.connect()
        }
        #expect(await result.value == nil)
        #expect(openCount >= MobileSSHCmuxTUITopologyReconnect<FakeControl>.maximumRecoveryAttempts + 1)
        #expect(openCount <= MobileSSHCmuxTUITopologyReconnect<FakeControl>.maximumRecoveryAttempts + 2)
        #expect(first.isClosed)
    }

    @Test func retryBackoffIsBounded() {
        let delays = (0..<10).map(MobileSSHCmuxTUITopologyReconnect<FakeControl>.backoff(forAttempt:))
        #expect(delays.prefix(6) == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)])
        #expect(delays.dropFirst(6).allSatisfy { $0 == .seconds(30) })
    }

    @Test func staleGenerationCannotClearOrAdmitNewSnapshot() {
        var gate = MobileSSHCmuxTUITopologyGate()
        gate.generationChanged(to: 1)
        let admittedFirst = gate.admit(.treeChanged, generation: 1)
        #expect(admittedFirst)
        gate.generationChanged(to: 2)
        gate.listed(generation: 1)
        let admittedStale = gate.admit(.surfaceExited(surface: 7), generation: 1)
        #expect(!admittedStale)
        let snapshotBeforeListing = gate.forceSnapshotIfNeeded(generation: 2)
        #expect(!snapshotBeforeListing)

        gate.listed(generation: 2)
        gate.generationChanged(to: 3)
        let snapshotAfterGap = gate.forceSnapshotIfNeeded(generation: 3)
        #expect(snapshotAfterGap)
        let admittedOld = gate.admit(.treeChanged, generation: 2)
        #expect(!admittedOld)
    }

    @Test func providerListingDiscardsRowsFromAStaleGeneration() async throws {
        let gate = Gate()
        var generation: UInt64 = 1
        var loadCount = 0
        let stale = MobileSSHWorkspace(id: "stale", name: "stale", terminals: [])
        let current = MobileSSHWorkspace(id: "current", name: "current", terminals: [])

        let listing = Task { @MainActor in
            try await MobileSSHCmuxTUIProvider.stableWorkspaceListing(
                generation: { generation },
                load: {
                    loadCount += 1
                    if loadCount == 1 {
                        await gate.signal()
                        await gate.wait()
                        return [stale]
                    }
                    return [current]
                }
            )
        }

        await gate.wait()
        generation = 2
        await gate.signal()
        let result = try await listing.value
        #expect(result == [current])
        #expect(loadCount == 2)
    }

    @Test func providerListingBoundsContinuousGenerationChurn() async {
        var generation: UInt64 = 1
        var loadCount = 0
        do {
            _ = try await MobileSSHCmuxTUIProvider.stableWorkspaceListing(
                generation: { generation },
                load: {
                    loadCount += 1
                    generation += 1
                    return []
                }
            )
            Issue.record("a continuously changing topology must not return a stale snapshot")
        } catch let error as CmuxTUIError {
            #expect(error == .commandFailed(
                command: "list-workspaces",
                message: "workspace topology changed during snapshot",
                code: "topology-unstable"
            ))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(loadCount == MobileSSHCmuxTUIProvider.maximumStableListingAttempts)
    }
}
