import CmuxLink
@_spi(Testing) import CmuxLinkWebRTC
import Foundation
import Testing

extension LiveWebRTCTests {
    @Suite("WebRTC room waiter cancellation")
    struct RoomCancellationTests {
        private static let lane = TransportLane(reliability: .reliableOrdered, priority: .bulk)

        @Test("cancelling one room waiter leaves other waiters and the peer alive")
        func cancellationRemovesOnlyTheSelectedWaiter() async throws {
            let pair = await WebRTCPair()
            let (dialer, _) = try await within { try await pair.connect() }
            let peer = dialer.connection.peer
            let key = LaneLabel(lane: Self.lane).label
            Self.fillQueue(peer, key: key)

            let first = Task { try await peer.waitForRoom(key) }
            try await Self.waitForWaiter(peer, key: key, count: 1)
            let second = Task { try await peer.waitForRoom(key) }
            try await Self.waitForWaiter(peer, key: key, count: 2)

            second.cancel()
            await #expect(throws: CancellationError.self) {
                try await within(.seconds(1)) { try await second.value }
            }
            #expect(Self.waiterCount(peer, key: key) == 1)
            #expect(!peer.isClosed)

            first.cancel()
            await #expect(throws: CancellationError.self) {
                try await within(.seconds(1)) { try await first.value }
            }
            #expect(Self.waiterCount(peer, key: key) == 0)
            #expect(!peer.isClosed)
            await dialer.close()
            await pair.stop()
        }

        @Test("a send that is already cancelled never registers a room waiter")
        func preCancelledWaiterDoesNotStrand() async throws {
            let pair = await WebRTCPair()
            let (dialer, _) = try await within { try await pair.connect() }
            let peer = dialer.connection.peer
            let key = LaneLabel(lane: Self.lane).label
            Self.fillQueue(peer, key: key)

            let cancelled = Task { try await peer.waitForRoom(key) }
            cancelled.cancel()
            await #expect(throws: CancellationError.self) {
                try await within(.seconds(1)) { try await cancelled.value }
            }
            #expect(Self.waiterCount(peer, key: key) == 0)
            #expect(!peer.isClosed)
            await dialer.close()
            await pair.stop()
        }

        private static func fillQueue(_ peer: WebRTCPeer, key: String) {
            let label = LaneLabel(lane: lane)
            peer.state.withLockUnchecked { state in
                var queue = LaneQueue(label: label)
                queue.append([Data(repeating: 0xA5, count: peer.limits.laneBudget)])
                state.laneQueues[key] = queue
            }
        }

        private static func waiterCount(_ peer: WebRTCPeer, key: String) -> Int {
            peer.state.withLockUnchecked { $0.roomWaiters[key]?.count ?? 0 }
        }

        private static func waitForWaiter(_ peer: WebRTCPeer, key: String, count: Int) async throws {
            try await within(.seconds(1)) {
                while waiterCount(peer, key: key) < count { await Task.yield() }
            }
        }
    }
}
