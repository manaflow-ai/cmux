import CmuxMobileModel
import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The phone's side of the Mac's terminal sizing policy
/// (cmux-next-ios/PROTOCOL.md "Terminal sizing policy (host-size-policy-v1)"):
/// the attach joins shared sizing, the terminal's size state reaches the
/// page live, typing on the phone counts as its activity on the Mac (so
/// "Prefer the Active Device" can pick it), and the Mac's policy is read and
/// set over a `daemon` channel.
@MainActor @Suite struct DaemonTerminalSizingPolicyTests {
    private func session(_ daemon: FakeTerminalDaemon) -> DaemonTerminalSession {
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        return DaemonTerminalSession(surface: 7, clientInfo: ["device_kind": "iphone"]) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
    }

    private func commands(_ daemon: FakeTerminalDaemon, _ cmd: String) -> [[String: Any]] {
        daemon.recorded.filter { $0["cmd"] as? String == cmd }
    }

    @Test func theAttachJoinsSharedSizing() async throws {
        let daemon = FakeTerminalDaemon()
        let session = session(daemon)
        session.start { _ in }
        try await waitUntil { !commands(daemon, "set-client-info").isEmpty }
        let info = try #require(commands(daemon, "set-client-info").first)
        let capabilities = info["capabilities"] as? [String] ?? []
        #expect(capabilities.contains("size-lease-v1"))
        #expect(capabilities.contains("shared-sizing-v1"))
        // The phone renders a larger host grid (pans, letterboxes), so it says so.
        #expect(capabilities.contains("host-grid-view-v1"))
    }

    @Test func theSizeStateReachesThePageLive() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.sharedSizing = true
        let session = session(daemon)
        session.start { _ in }
        try await waitUntil { session.sizing.state?.generation == 2 }
        #expect(session.sizing.selfParticipant == "c2")
        #expect(session.sizing.state?.participants.map(\.id) == ["c1", "c2"])
        #expect(session.sizing.state?.participants[1].viewport == TerminalGrid(cols: 80, rows: 30))
        #expect(session.sizing.selfIsOwner)
    }

    @Test func typingNotesActivityAtMostOnceASecondWhileNotOwner() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.sharedSizing = true
        daemon.owners = ["c1"]
        let session = session(daemon)
        var clock: TimeInterval = 100
        session.now = { clock }
        session.start { _ in }
        try await waitUntil { session.sizing.state?.generation == 2 }
        session.send(Data("a".utf8))
        session.send(Data("b".utf8))
        session.noteInteraction()
        try await waitUntil { commands(daemon, "send").count >= 1 }
        try await waitUntil { commands(daemon, "note-size-activity").count == 1 }
        try await settle()
        #expect(commands(daemon, "note-size-activity").count == 1)
        #expect(commands(daemon, "note-size-activity").first?["surface"] as? Int == 7)
        clock += 1.1
        session.noteInteraction()
        try await waitUntil { commands(daemon, "note-size-activity").count == 2 }
    }

    @Test func anOwnerOrAnOlderMacGetsNoActivityNote() async throws {
        let owner = FakeTerminalDaemon()
        owner.sharedSizing = true
        let ownerSession = session(owner)
        ownerSession.start { _ in }
        try await waitUntil { ownerSession.sizing.state?.generation == 2 }
        ownerSession.send(Data("a".utf8))
        try await waitUntil { commands(owner, "send").count == 1 }

        let older = FakeTerminalDaemon()
        let olderSession = session(older)
        olderSession.start { _ in }
        try await waitUntil { olderSession.isAttached }
        olderSession.send(Data("a".utf8))
        try await waitUntil { commands(older, "send").count == 1 }
        try await settle()
        #expect(commands(owner, "note-size-activity").isEmpty)
        #expect(commands(older, "note-size-activity").isEmpty)
    }

    @Test func readsAndSetsTheMacsPolicy() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.sharedSizing = true
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let client = DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        await client.start()
        let channel = HostSizePolicyChannel(client: client)

        let info = try await channel.get(surface: 7)
        #expect(info == HostSizePolicyInfo(policy: HostSizePolicy(mode: .smallest), macParticipants: ["c1"]))
        #expect(commands(daemon, "get-host-size-policy").first?["surface"] as? Int == 7)

        let set = try await channel.set(HostSizePolicy(mode: .priority, order: ["device:ios-1", "mac"]))
        #expect(set == HostSizePolicy(mode: .priority, order: ["device:ios-1", "mac"]))
        let line = try #require(commands(daemon, "set-host-size-policy").first)
        let policy = try #require(line["policy"] as? [String: Any])
        #expect(policy["mode"] as? String == "priority")
        #expect(policy["order"] as? [String] == ["device:ios-1", "mac"])
        #expect(Set(line.keys) == ["id", "cmd", "policy"])
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
