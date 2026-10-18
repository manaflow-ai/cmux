import Darwin
import Foundation
import Testing
@testable import CmuxCloud

@Suite struct CloudBrowserProxyQuitRegistryTests {
    final class SignalLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(pid_t, Int32)] = []
        func record(_ pid: pid_t, _ signal: Int32) { lock.lock(); entries.append((pid, signal)); lock.unlock() }
        var all: [(pid_t, Int32)] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    @Test func appQuitKillsOnlyStillRunningCarriersOnce() {
        let log = SignalLog()
        let registry = CloudBrowserProxyQuitRegistry { log.record($0, $1) }
        let live = UUID(), exited = UUID()
        registry.register(live, pid: 4242)
        registry.register(exited, pid: 4343)
        registry.unregister(exited)

        registry.terminateAllForAppQuit()
        registry.terminateAllForAppQuit()

        #expect(log.all.map(\.0) == [4242])
        #expect(log.all.map(\.1) == [SIGKILL])
        #expect(registry.registeredCount == 0)
    }

    @Test func invalidPIDIsNeverRegistered() {
        let log = SignalLog()
        let registry = CloudBrowserProxyQuitRegistry { log.record($0, $1) }
        registry.register(UUID(), pid: 0)
        registry.terminateAllForAppQuit()
        #expect(log.all.isEmpty)
    }
}
