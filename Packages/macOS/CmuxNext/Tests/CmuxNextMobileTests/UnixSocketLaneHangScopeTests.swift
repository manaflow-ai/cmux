import CmuxNextMobile
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing

/// The mobile lane to the daemon registers the `mobile.unix-lane` lane: each Network callback on its queue (a
/// state change, a write's end, a read) is one 1 s scope, the read and the write wait in none, and the lane is
/// freed with the connection (plans/cmux-next/chrome-parity/p09-observability.md, section E, task 119).
@Suite(.timeLimit(.minutes(1)))
struct UnixSocketLaneHangScopeTests {
    private static let lane = "mobile.unix-lane"

    @Test func eachCallbackIsOneScopeAndTheLaneIsFreedWithTheConnection() async throws {
        let listener = try UnixTestListener()
        defer { listener.close() }
        let hangs = RecordingLaneHangWatch()
        var lane: UnixSocketLane? = try await UnixSocketLane.connect(path: listener.path, hangs: hangs)
        #expect(hangs.lanes == [Self.lane])
        let connected = hangs.entered(Self.lane)
        #expect(connected >= 1, "the ready state was handled outside a scope")
        let server = try listener.accept()
        defer { Darwin.close(server) }

        try await lane?.write(Data("ping".utf8))
        #expect(hangs.entered(Self.lane) == connected + 1, "a write's end was not one scope")

        // SAFETY: `send` reads 4 bytes from the literal's buffer during the call.
        let sent = unsafe "pong".withCString { unsafe Darwin.send(server, $0, 4, 0) }
        #expect(sent == 4)
        let read = try await lane?.read(maximumBytes: 16)
        #expect(read == Data("pong".utf8))
        #expect(hangs.entered(Self.lane) == connected + 2, "a read's delivery was not one scope")
        #expect(hangs.entered.allSatisfy { $0.deadline == .seconds(1) })

        await lane?.close()
        lane = nil
        #expect(hangs.unregistered == [Self.lane])
    }
}
