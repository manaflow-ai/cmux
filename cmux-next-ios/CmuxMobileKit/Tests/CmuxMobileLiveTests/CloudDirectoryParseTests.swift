#if os(iOS)
import CmuxMobileChief
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

private actor ReplyChannel: LinkChannel {
    nonisolated let id: UInt32 = 1
    private var chunks: [Data]
    init(_ json: String) { chunks = [Data(json.utf8)] }
    func send(_ data: Data) async throws {}
    func receive() async throws -> Data? { chunks.isEmpty ? nil : chunks.removeFirst() }
    func close(code: String, reason: String) async { chunks = [] }
}

/// The `cloud-directory` reply's `paid`, `status` and `ran`
/// (https://github.com/manaflow-ai/cmux/issues/31488), and an older Mac's reply without them.
@Suite struct CloudDirectoryParseTests {
    @Test func readsPaidStatusAndRan() async throws {
        let directory = try await CloudChatDirectory.readDirectory(ReplyChannel(#"""
        {"paid":true,"desktops":true,"machines":[
          {"machine_id":"m1","team_id":"t1","name":"Dev box","status":"running","ran":true},
          {"machine_id":"m2","team_id":"t1","name":"New box","status":"provisioning","ran":false}]}
        """#))
        #expect(directory.paid)
        #expect(directory.desktops)
        #expect(directory.machines.map(\.status) == ["running", "provisioning"])
        #expect(directory.machines.map(\.ran) == [true, false])
        let computer = LiveCoordinator.computerDirectory(directory)
        #expect(computer.computer?.machineID == "m1")
        #expect(computer.computer?.name == "Dev box")
    }

    @Test func aMacWithCloudDesktopsOffHidesTheCard() async throws {
        let directory = try await CloudChatDirectory.readDirectory(ReplyChannel(#"""
        {"paid":true,"desktops":false,"machines":[
          {"machine_id":"m1","team_id":"t1","name":"Dev box","status":"running","ran":true}]}
        """#))
        #expect(!LiveCoordinator.computerDirectory(directory).showsComputer)
    }

    @Test func anOlderMacsReplyHidesTheCard() async throws {
        let directory = try await CloudChatDirectory.readDirectory(ReplyChannel(
            #"{"machines":[{"machine_id":"m1","team_id":"t1","name":"Dev box"}]}"#))
        #expect(!directory.paid)
        #expect(!directory.desktops)
        #expect(directory.machines.first?.status == nil)
        #expect(directory.machines.first?.ran == false)
        #expect(!LiveCoordinator.computerDirectory(directory).showsComputer)
        // The Cloud chats list still reads the same reply.
        let machines = try await CloudChatDirectory.read(ReplyChannel(
            #"{"machines":[{"machine_id":"m1","team_id":"t1","name":"Dev box"}]}"#))
        #expect(machines.map(\.machineID) == ["m1"])
    }
}
#endif
