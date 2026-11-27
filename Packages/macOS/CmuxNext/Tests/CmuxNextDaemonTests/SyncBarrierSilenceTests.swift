import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// no-hangs (2026-11-24): the `after: "sync"` barrier sent `identify` with no deadline, so a daemon
/// that stopped answering while its process lived (SIGSTOP, a wedged main loop) kept a `cmux ...
/// --after sync` waiting forever: the heartbeat keeps such a connection open (P0 2026-10-30). The
/// barrier's wait now ends at the heartbeat's not-answering verdict (silence), never at a clock that
/// measures slowness, and a create on the same connection still gets its late reply.
@Suite(.timeLimit(.minutes(1))) struct SyncBarrierSilenceTests {
    @Test func aSilentLiveDaemonEndsTheBarriersWaitAtTheVerdictAndACreateStillSucceeds() async throws {
        let daemon = try SlowDaemon()
        defer { daemon.stop() }
        let transport = try LineTransport(path: daemon.path)
        defer { transport.close() }
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        let heartbeat = ConnectionHeartbeat()
        heartbeat.start(transport, every: .milliseconds(40), misses: 2)
        defer { heartbeat.stop() }

        let create = Task {
            try await transport.request(cmd: "create-workspace", timeout: nil) { id in
                Data(#"{"id":\#(id),"cmd":"create-workspace"}"#.utf8)
            }
        }
        let started = ContinuousClock.now
        let barrier = try await heartbeat.untilSilent {
            _ = try await transport.request(cmd: IdentifyRequest.command, timeout: nil) { id in
                try WireCoding.encodeRequest(IdentifyRequest(), id: id)
            }
        }
        #expect(barrier == nil, "the barrier's identify got an answer from a daemon that answers nothing")
        #expect(ContinuousClock.now - started < .seconds(10), "the barrier waited past the heartbeat's verdict")
        #expect(!heartbeat.answering)
        #expect(!transport.isClosed, "a live daemon's connection must stay open")

        // The silence ended only the barrier's wait: the create is still the daemon's to answer.
        daemon.answerEverything()
        switch await create.result {
        case .success: break
        case .failure(let error): Issue.record("the create failed while the daemon was alive: \(error)")
        }
    }

    /// A barrier asked while the daemon is already not answering ends at the next verdict, not at once.
    @Test func aBarrierAskedDuringSilenceEndsAtTheNextVerdict() async throws {
        let daemon = try SlowDaemon()
        defer { daemon.stop() }
        let transport = try LineTransport(path: daemon.path)
        defer { transport.close() }
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        let heartbeat = ConnectionHeartbeat()
        heartbeat.start(transport, every: .milliseconds(40), misses: 2)
        defer { heartbeat.stop() }
        #expect(await daemon.waitForAsks(3) == .asked)

        let barrier = try await heartbeat.untilSilent { () async throws -> Int in
            try await Task.sleep(for: .seconds(30))
            return 1
        }
        #expect(barrier == nil)
    }

    /// An answering daemon's barrier gets its value: the bound never fails a reply that comes.
    @Test func anAnsweringDaemonsBarrierGetsItsReply() async throws {
        let daemon = try SlowDaemon()
        defer { daemon.stop() }
        daemon.answerEverything()
        let transport = try LineTransport(path: daemon.path)
        defer { transport.close() }
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        let heartbeat = ConnectionHeartbeat()
        heartbeat.start(transport, every: .milliseconds(40), misses: 2)
        defer { heartbeat.stop() }

        let barrier = try await heartbeat.untilSilent {
            _ = try await transport.request(cmd: IdentifyRequest.command, timeout: nil) { id in
                try WireCoding.encodeRequest(IdentifyRequest(), id: id)
            }
            return true
        }
        #expect(barrier == true)
    }
}
