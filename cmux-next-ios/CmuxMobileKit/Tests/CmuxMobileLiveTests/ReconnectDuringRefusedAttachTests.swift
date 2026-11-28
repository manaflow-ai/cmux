import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The link comes back (`reconnect()`) while an attach on the old link is still out, and that
/// attach is then refused ("unknown surface") with no retries left: the session attaches on the
/// new link, never gives up with the Mac back. `ReconnectShowsCacheTests` hit this under a slow
/// simulator: its first attach was still out when its link-return `reconnect()` ran, and the
/// session ended `.failed` ("unknown surface 7").
@MainActor @Suite struct ReconnectDuringRefusedAttachTests {
    /// Holds the first channel open until released, so the attach is out while the link returns.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var opens = 0

        func pass() async {
            let first: Bool = lock.withLock { opens += 1; return opens == 1 && !released }
            guard first else { return }
            await withCheckedContinuation { continuation in
                let resumeNow: Bool = lock.withLock {
                    if released { return true }
                    waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        var opened: Int { lock.withLock { opens } }

        func release() {
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                released = true
                defer { self.waiter = nil }
                return self.waiter
            }
            waiter?.resume()
        }
    }

    @Test func aLinkReturnDuringARefusedAttachAttachesOnTheNewLink() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.afterAttach = nil
        daemon.failNextAttaches = 1
        let gate = Gate()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            await gate.pass()
            return DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        session.reattachBackoff = []
        // Not the 8 s fresh round: only the remembered link return may attach here.
        session.gaveUpRetryDelay = .seconds(600)
        defer { session.stop() }
        session.start { _ in }
        try await waitUntil { gate.opened == 1 }
        // The link is back while the first attach is out.
        session.reconnect()
        gate.release()
        try await waitUntil { session.isAttached }
        #expect(session.isAttached, "last error \(session.lastError ?? "none")")
        #expect(session.connectionState == .attached)
        #expect(daemon.recorded.filter { $0["cmd"] as? String == "attach-surface" }.count == 2)
    }

    /// Without a link return the refusal still gives up (no retries left): the remembered
    /// reconnect is the only new attach.
    @Test func aRefusedAttachWithNoLinkReturnStillGivesUp() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.afterAttach = nil
        daemon.failNextAttaches = 1
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        session.reattachBackoff = []
        session.gaveUpRetryDelay = .seconds(600)
        defer { session.stop() }
        session.start { _ in }
        try await waitUntil { if case .failed = session.connectionState { true } else { false } }
        #expect(!session.isAttached)
        #expect(daemon.recorded.filter { $0["cmd"] as? String == "attach-surface" }.count == 1)
    }

    private func waitUntil(attempts: Int = 400, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10)) // test: polls a session transition
        }
    }
}
