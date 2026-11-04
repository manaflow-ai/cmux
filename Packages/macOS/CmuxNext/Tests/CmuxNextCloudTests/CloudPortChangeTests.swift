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

    @Test func snapshotFrameDoesNotCreateAnOpening() {
        let frame = Data(#"{"t":"snapshot","event":"cloud.machine.event","data":{"machine":"vm_a","kind":"service.port.opened","data":{"port":3000}}}"#.utf8)
        #expect(CloudPortChange.parseWireFrame(frame) == nil)
    }

    @Test func ignoresUnrelatedWireFrames() throws {
        let data = try JSONSerialization.data(withJSONObject: ["t": "ephemeral", "event": "other", "data": [:]])
        #expect(CloudPortChange.parseWireFrame(data) == nil)
    }
}
