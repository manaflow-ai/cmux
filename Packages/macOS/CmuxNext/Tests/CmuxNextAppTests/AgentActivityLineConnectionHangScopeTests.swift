@testable import CmuxNextAgentActivity
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The agent activity connection registers the `agent-activity.socket` lane: each job on its queue (the connect
/// and its check, a read, an end) is one 1 s scope, and a send, which blocks until the peer reads, is in none
/// (plans/cmux-next/chrome-parity/p09-observability.md, section E, task 119). The listener never accepts: a
/// connect completes in its backlog and a short send fits its buffer.
@Suite(.timeLimit(.minutes(1)))
struct AgentActivityLineConnectionHangScopeTests {
    nonisolated static let lane = "agent-activity.socket"

    @Test func eachJobButASendIsOneScope() async throws {
        let listener = try UnixTestListener()
        defer { listener.close() }
        let hangs = RecordingLaneHangWatch()
        let connection = AgentActivityLineConnection(path: listener.path, hangs: hangs)
        #expect(hangs.lanes == [Self.lane])
        #expect(AgentActivityLineConnection.hangDeadline == .seconds(1))

        let (expiries, expired) = AsyncStream.makeStream(of: (depth: Int, entered: Int).self)
        connection.onExpire = { expired.yield((hangs.open(Self.lane).count, hangs.entered(Self.lane))) }
        connection.start(send: Data("{}\n".utf8), onLine: { _ in }, onClose: {})
        connection.send(Data("{}\n".utf8))
        connection.expire()

        // The expiry runs in its own scope, after the start's one scope and the send's none.
        var expiry = expiries.makeAsyncIterator()
        let seen = try #require(await expiry.next())
        #expect(seen.depth == 1)
        #expect(seen.entered == 2, "the start and the expiry are not two scopes, or a send opened one")
        #expect(hangs.entered.allSatisfy { $0.deadline == .seconds(1) })
    }

    @Test func aRefusedConnectEndsInsideTheStartsScope() async throws {
        let hangs = RecordingLaneHangWatch()
        let connection = AgentActivityLineConnection(path: NSTemporaryDirectory() + "no-such-\(UUID().uuidString.prefix(8)).sock",
                                                     hangs: hangs)
        let (closes, closed) = AsyncStream.makeStream(of: Int.self)
        connection.start(send: Data("{}\n".utf8), onLine: { _ in }, onClose: { closed.yield(hangs.open(Self.lane).count) })
        var close = closes.makeAsyncIterator()
        #expect(await close.next() == 1)
    }

    @Test func theLaneIsFreedWithTheConnection() {
        let hangs = RecordingLaneHangWatch()
        var connection: AgentActivityLineConnection? = AgentActivityLineConnection(path: "/unused", hangs: hangs)
        #expect(connection != nil)
        connection = nil
        #expect(hangs.unregistered == [Self.lane])
    }
}
