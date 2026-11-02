import Foundation
import Network
import Testing
@testable import CmuxNextRemoteLocalhost

/// The proxy's trust check is a run of blocking `proc_pid*` calls. It runs one at a time on its own queue, so
/// a flood of local connections neither holds cooperative-pool threads nor runs many scans at once.
struct PeerProcessScanTests {
    private final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var peak = 0
        private(set) var finished = 0

        func slowScan() -> Bool {
            lock.withLock {
                running += 1
                peak = max(peak, running)
            }
            usleep(20_000)
            lock.withLock {
                running -= 1
                finished += 1
            }
            return true
        }
    }

    private func check(_ gauge: Gauge) async -> Bool {
        await PeerProcess.isTrustedOffPool(peerHost: .ipv4(.loopback), peerPort: 50_000, localHost: .ipv4(.loopback),
                                           localPort: 50_001, scan: { gauge.slowScan() })
    }

    @Test func scansRunOneAtATime() async {
        let gauge = Gauge()
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 { group.addTask { await check(gauge) } }
            for await trusted in group { #expect(trusted) }
        }
        #expect(gauge.finished == 32)
        #expect(gauge.peak == 1, "\(gauge.peak) scans ran at once")
    }

    /// With 64 scans pending, the cooperative pool still runs other work: a canary task finishes long before
    /// the scans (64 x 20 ms) do.
    @Test func pendingScansDoNotStarveTheCooperativePool() async {
        let gauge = Gauge()
        let started = ContinuousClock.now
        var canaryDuration = Duration.zero
        await withTaskGroup(of: Duration?.self) { group in
            for _ in 0..<64 { group.addTask { _ = await check(gauge); return nil } }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(50))
                return ContinuousClock.now - started
            }
            for await finished in group { if let finished { canaryDuration = finished } }
        }
        #expect(canaryDuration < .milliseconds(600), "the canary waited \(canaryDuration) behind the scans")
        #expect(gauge.finished == 64)
    }

    @Test func aPeerThatIsNotThisProcessIsNotTrusted() async {
        let trusted = await PeerProcess.isTrustedOffPool(peerHost: .ipv4(.loopback), peerPort: 1, localHost: .ipv4(.loopback),
                                                         localPort: 2)
        #expect(!trusted)
    }
}
