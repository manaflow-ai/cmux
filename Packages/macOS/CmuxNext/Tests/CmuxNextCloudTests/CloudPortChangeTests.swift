import Foundation
@testable import CmuxNextCloud
import Testing

struct CloudPortChangeTests {
    @Test func parsesEphemeralMachinePortEvent() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "t": "ephemeral",
            "stream": "cloud:team_0123456789abcdef0123",
            "event": "cloud.machine.event",
            "data": [
                "machine": "vm_01234567890123456789",
                "kind": "service.port.opened",
                "data": ["port": 3000, "proto": "tcp", "process": "vite"],
            ],
        ])
        let change = try #require(CloudPortChange.parseWireFrame(data))
        #expect(change.machineID == "vm_01234567890123456789")
        #expect(change.port == 3000)
        #expect(change.process == "vite")
        #expect(change.state == .opened)
    }

    @Test func snapshotPortReplayIsKnownInsteadOfNew() throws {
        let frame = Data(#"{"t":"ephemeral","event":"cloud.machine.event","data":{"machine":"vm_a","kind":"service.port.opened","data":{"port":3000,"proto":"tcp","snapshot":true}}}"#.utf8)
        let change = try #require(CloudPortChange.parseWireFrame(frame))
        #expect(change.known)
        #expect(change.port == 3000)
    }

    @Test func replayedPortReplayIsKnownInsteadOfNew() throws {
        let frame = Data(#"{"t":"ephemeral","replayed":true,"event":"cloud.machine.event","data":{"machine":"vm_a","kind":"service.port.opened","data":{"port":3000,"proto":"tcp"}}}"#.utf8)
        let change = try #require(CloudPortChange.parseWireFrame(frame))
        #expect(change.known)
    }

    @Test func snapshotFrameDoesNotCreateAnOpening() {
        let frame = Data(#"{"t":"snapshot","event":"cloud.machine.event","data":{"machine":"vm_a","kind":"service.port.opened","data":{"port":3000}}}"#.utf8)
        #expect(CloudPortChange.parseWireFrame(frame) == nil)
    }

    @Test func onlyTCPListenersArePreviews() throws {
        let udp = Data(#"{"t":"ephemeral","event":"cloud.machine.event","data":{"machine":"vm_a","kind":"service.port.opened","data":{"port":5353,"proto":"udp"}}}"#.utf8)
        #expect(try #require(CloudPortChange.parseWireFrame(udp)).isBrowserPreview == false)
        let unnamed = Data(#"{"t":"ephemeral","event":"cloud.machine.event","data":{"machine":"vm_a","kind":"service.port.opened","data":{"port":3000}}}"#.utf8)
        #expect(try #require(CloudPortChange.parseWireFrame(unnamed)).isBrowserPreview)
    }

    @Test func ignoresUnrelatedWireFrames() throws {
        let data = try JSONSerialization.data(withJSONObject: ["t": "ephemeral", "event": "other", "data": [:]])
        #expect(CloudPortChange.parseWireFrame(data) == nil)
    }

    /// A snapshot's spares needing login go to the same handler as the event, for the socket's own team only.
    @Test func aSnapshotNamesItsSparesNeedingLoginForTheSocketsTeamOnly() throws {
        let team = "team_0123456789abcdef0123"
        let frame = try JSONSerialization.data(withJSONObject: [
            "t": "snapshot", "stream": "cloud:\(team)", "seq": 3, "state": [:] as [String: Any],
            "spares_needing_login": ["vm_01234567890123456789", "not-a-vm", 7],
        ] as [String: Any])
        #expect(CloudMachineWire.sparesNeedingLogin(frame, team: team) == ["vm_01234567890123456789"])
        #expect(CloudMachineWire.sparesNeedingLogin(frame, team: "team_ffffffffffffffffffff").isEmpty)
        #expect(CloudMachineWire.sparesNeedingLogin(frame, team: nil).isEmpty)
        let none = try JSONSerialization.data(withJSONObject: ["t": "snapshot", "stream": "cloud:\(team)", "seq": 3])
        #expect(CloudMachineWire.sparesNeedingLogin(none, team: team).isEmpty)
        #expect(CloudMachineWire.spareReady(frame, team: team) == nil)
    }

    /// A spare-ready frame names its machine only for the socket's own team, and is never a port change.
    @Test func aSpareReadyFrameNamesItsMachineForTheSocketsTeamOnly() throws {
        let frame = try JSONSerialization.data(withJSONObject: [
            "t": "ephemeral", "stream": "cloud:team_0123456789abcdef0123", "event": "cloud.spare.ready",
            "data": ["machine": "vm_01234567890123456789", "team": "team_0123456789abcdef0123", "at": 1],
        ])
        #expect(CloudMachineWire.spareReady(frame, team: "team_0123456789abcdef0123") == "vm_01234567890123456789")
        #expect(CloudMachineWire.spareReady(frame, team: "team_ffffffffffffffffffff") == nil)
        #expect(CloudMachineWire.spareReady(frame, team: nil) == nil)
        #expect(CloudPortChange.parseWireFrame(frame) == nil)
        let port = try JSONSerialization.data(withJSONObject: ["t": "ephemeral", "event": "cloud.machine.event", "data": ["team": "team_0123456789abcdef0123", "machine": "vm_01234567890123456789"]])
        #expect(CloudMachineWire.spareReady(port, team: "team_0123456789abcdef0123") == nil)
    }
}
