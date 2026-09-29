import CmuxMobileSSH
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextMobile

/// The phone half of a daemon lane as a `CmuxTUICarrier` over an in-memory
/// pipe (the irx lane is replaced by memory; everything else is real).
private final class MemoryCarrier: CmuxTUICarrier {
    let events: AsyncStream<SSHSessionEvent>
    private let lane: MemoryLane
    private let pump: Task<Void, Never>

    init(lane: MemoryLane) {
        self.lane = lane
        let (events, continuation) = AsyncStream.makeStream(of: SSHSessionEvent.self)
        self.events = events
        pump = Task {
            while let chunk = try? await lane.read(maximumBytes: 65_536) { continuation.yield(.stdout(chunk)) }
            continuation.yield(.closed)
            continuation.finish()
        }
    }

    func write(_ data: Data) async throws { try await lane.write(data) }
    func close() async {
        pump.cancel()
        await lane.close()
    }
}

/// The iOS app's `CmuxTUIControl` (what a new phone runs) through the
/// daemon-lane authority filter to a real cmux-tui daemon.
@Suite(.enabled(if: LiveBinary.url != nil, "no cmux-tui binary"), .timeLimit(.minutes(2)))
struct PhoneClientOverDaemonLaneTests {
    @Test func phoneClientListsCreatesAttachesTypesThroughTheLane() async throws {
        try await LiveDaemon.with { control, endpoint in
            let (phoneSide, phoneRemote) = MemoryLane.pair()
            let daemon = try await UnixSocketLane.connect(path: endpoint.socketPath)
            let splice = DaemonLaneSplice(phone: phoneSide, daemon: daemon, policy: DaemonLanePolicy(deviceID: "phone"))
            let run = Task { await splice.run() }

            let client = try await CmuxTUIControl.open(carrier: MemoryCarrier(lane: phoneRemote), session: nil,
                                                       clientName: "cmux-ios-test", handshakeTimeout: .seconds(10))
            let created = try await client.createWorkspace(name: "from-phone", cols: 80, rows: 24)
            let surface = try #require(created.terminal?.surface)
            #expect(try await client.listWorkspaces().contains { $0.name == "from-phone" })

            let attachment = try await client.attach(surface: surface, cols: 80, rows: 24)
            try await attachment.write(Data("echo lane-$((40+2))\r".utf8))
            var output = ""
            let watchdog = Task { try await Task.sleep(for: .seconds(20)); await client.close() }
            for await event in attachment.events {
                if case .output(let data) = event { output += String(decoding: data, as: UTF8.self) }
                if output.contains("lane-42") { break }
            }
            watchdog.cancel()
            #expect(output.contains("lane-42"))
            // The Mac side sees the phone's workspace too.
            #expect(try await control.listWorkspaces().workspaces.contains { $0.name == "from-phone" })
            await client.close()
            _ = await run.value
        }
    }
}
