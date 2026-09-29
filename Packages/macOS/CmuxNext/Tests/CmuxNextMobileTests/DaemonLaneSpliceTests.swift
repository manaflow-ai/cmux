import Foundation
import Testing
@testable import CmuxNextMobile

struct DaemonLaneSpliceTests {
    @Test func forwardsAllowedAndAnswersRefusedWithoutReachingDaemon() async throws {
        let (phoneSide, phoneRemote) = MemoryLane.pair()
        let (daemonSide, daemonRemote) = MemoryLane.pair()
        let splice = DaemonLaneSplice(phone: phoneSide, daemon: daemonSide, policy: DaemonLanePolicy(deviceID: "p"))
        let run = Task { await splice.run() }

        // Split one request across two writes, and send a forbidden one.
        try await phoneRemote.write(Data(#"{"id":"r1","cmd":"list-"#.utf8))
        try await phoneRemote.write(Data("workspaces\"}\n{\"id\":\"r2\",\"cmd\":\"shutdown-daemon\"}\n".utf8))

        let forwarded = await daemonRemote.readLines(1)
        #expect(forwarded == [#"{"id":"r1","cmd":"list-workspaces"}"#])

        // Daemon output passes through; the refusal is a separate whole line.
        try await daemonRemote.write(Data(#"{"id":"r1","ok":true,"data":{"workspaces":[]}}"#.utf8 + [0x0A]))
        let received = await phoneRemote.readLines(2)
        #expect(received.contains(#"{"id":"r1","ok":true,"data":{"workspaces":[]}}"#))
        let refusal = try #require(received.first { $0.contains("r2") })
        #expect(refusal.contains("forbidden"))
        #expect(await splice.refusedCount == 1)

        await phoneRemote.close()
        #expect(await run.value == .phoneClosed)
        #expect(try await daemonRemote.read(maximumBytes: 10) == nil)
    }

    @Test func daemonCloseEndsPhoneLane() async throws {
        let (phoneSide, phoneRemote) = MemoryLane.pair()
        let (daemonSide, daemonRemote) = MemoryLane.pair()
        let splice = DaemonLaneSplice(phone: phoneSide, daemon: daemonSide, policy: DaemonLanePolicy(deviceID: "p"))
        let run = Task { await splice.run() }
        await daemonRemote.close()
        #expect(await run.value == .daemonClosed)
        #expect(try await phoneRemote.read(maximumBytes: 10) == nil)
    }
}
