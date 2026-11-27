import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextControl
@testable import CmuxNextServer
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// `machine.list` and `device.join_line` (AppControl+Remote, CmuxNextServer MachineAutomation): a machine's row as the Machines section
/// lists it, the join line's phase as Add Device holds it, when the call presses Make Line, and a joined
/// row's id reaching its daemon for `machine.reconnect`.
@MainActor @Suite(.closesItsWindows, .serialized) struct MachineControlTests {
    private static let joined = JoinedMachine(id: "m_1", name: "lane-vm-3", state: .online, lastHeartbeat: "2026-11-07T10:00:00Z",
                                              platform: "linux", hostname: "lane-vm-3", meshPeerId: "peer-1", joinTokenId: "jt_1")

    @Test func aJoinedRowListsItsIdKindLinkAndHubFields() throws {
        let row = MachineSectionRow.joined(Self.joined, health: nil)
        let json = try #require(row.automationJSON(linkState: "connected").objectValue)
        #expect(json["id"]?.stringValue == "joined:m_1")
        #expect(json["kind"]?.stringValue == "joined")
        #expect(json["linkState"]?.stringValue == "connected")
        #expect(json["online"]?.boolValue == true)
        let hub = try #require(json["joined"]?.objectValue)
        #expect(hub["id"]?.stringValue == "m_1")
        #expect(hub["state"]?.stringValue == "online")
        #expect(hub["meshPeerId"]?.stringValue == "peer-1")
        #expect(hub["joinTokenId"]?.stringValue == "jt_1")
    }

    @Test func thisMacsRowHasNoHubFields() throws {
        let rows = MachineSectionRow.rows(MachineRegistry(local: DaemonService()), health: MachineHealthStore())
        let mac = try #require(rows.first)
        let json = try #require(mac.automationJSON(linkState: nil).objectValue)
        #expect(json["isLocal"]?.boolValue == true)
        #expect(json["kind"]?.stringValue == "local")
        #expect(json["joined"] == .null)
        #expect(json["linkState"] == .null)
    }

    @Test func aShownLineCarriesItsLineTokenIdAndTimeLeft() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let line = JoinLine(line: "curl -fsSL https://cmux.example/join.sh | CMUX_JOIN=cmj_X sh", joinTokenId: "jt_1",
                            expiresAt: now.addingTimeInterval(581.2), name: "build-box")
        let json = MachineJoinLineModel.Phase.showing(line).automationJSON(checks: [], now: now)
        #expect(json["phase"]?.stringValue == "showing")
        #expect(json["line"]?.stringValue == line.line)
        #expect(json["joinTokenId"]?.stringValue == "jt_1")
        #expect(json["secondsLeft"]?.intValue == 582)
        #expect(json["name"]?.stringValue == "build-box")
        #expect(json["expiresAt"]?.stringValue.flatMap(JoinLine.date) != nil)
    }

    @Test func afterTheFlipTheMachineShowsAndTheLineDoesNot() throws {
        let now = Date()
        let line = JoinLine(line: "secret line", joinTokenId: "jt_1", expiresAt: now.addingTimeInterval(60))
        let checks = [HostStepResult(step: HostStep(rawValue: "heartbeat"), state: .ok, detail: "12 s ago")]
        let json = MachineJoinLineModel.Phase.joined(line, Self.joined).automationJSON(checks: checks, now: now)
        #expect(json["phase"]?.stringValue == "joined")
        #expect(json["line"] == nil)
        #expect(try #require(json["joined"]?.objectValue)["id"]?.stringValue == "m_1")
        #expect(json["checks"]?.arrayValue?.count == 1)
        #expect(MachineJoinLineModel.Phase.failed(.signedOut).automationJSON(checks: [], now: now)["failure"]?.stringValue == "signedOut")
    }

    @Test func makeLineIsPressedOnlyWhenNoLineShows() {
        let line = JoinLine(line: "l", joinTokenId: "jt", expiresAt: Date().addingTimeInterval(60))
        #expect(MachineJoinLineModel.Phase.idle.mintsOnPress)
        #expect(MachineJoinLineModel.Phase.expired.mintsOnPress)
        #expect(MachineJoinLineModel.Phase.failed(.failed).mintsOnPress)
        #expect(!MachineJoinLineModel.Phase.minting.mintsOnPress)
        #expect(!MachineJoinLineModel.Phase.showing(line).mintsOnPress)
        #expect(!MachineJoinLineModel.Phase.joined(line, Self.joined).mintsOnPress)
    }

    @Test func theCallOpensTheCardPressesMakeLineOnceAndReadsTheLine() async throws {
        let fake = MachineJoinLineFlowTests.Fake()
        fake.line = JoinLine(line: "curl -fsSL https://cmux.example/join.sh | CMUX_JOIN=cmj_TEST sh", joinTokenId: "jt_9",
                             expiresAt: Date().addingTimeInterval(600), name: "build-box")
        let card = AddDeviceCard(services: MachineJoinLineFlowTests.services(AddDeviceFlowTests.Fake(), fake))
        defer { card.close() }
        let read = try #require(await card.automationJoinLine(["mint": .bool(false)], over: nil).objectValue)
        #expect(read["shown"]?.boolValue == true)
        #expect(read["way"]?.stringValue == "joinLine")
        #expect(read["phase"]?.stringValue == "idle", "a read alone presses nothing")
        #expect(fake.mints.isEmpty)
        let minted = try #require(await card.automationJoinLine(["mint": .bool(true), "name": .string("build-box")], over: nil).objectValue)
        #expect(minted["phase"]?.stringValue == "showing")
        #expect(minted["line"]?.stringValue == fake.line.line)
        #expect(minted["joinTokenId"]?.stringValue == "jt_9")
        #expect(fake.mints == ["build-box"])
        let again = try #require(await card.automationJoinLine(["mint": .bool(true)], over: nil).objectValue)
        #expect(again["joinTokenId"]?.stringValue == "jt_9", "a line still showing is never minted over")
        #expect(fake.mints.count == 1)
    }

    @Test func aJoinedRowIdReconnectsTheDaemonItIsReachedBy() {
        #expect(JoinedMachine.linkedMachine("joined:m_1", in: [Self.joined]) == "peer-1")
        #expect(JoinedMachine.linkedMachine("joined:m_2", in: [Self.joined]) == "joined:m_2")
        #expect(JoinedMachine.linkedMachine("cloud-a", in: [Self.joined]) == "cloud-a")
    }

    @Test func theJoinLineIsOffWithCloud() {
        #expect(ActionFeature(controlMethod: "device.join_line") == .cloud)
        #expect(ActionFeature(controlMethod: "machine.list") == nil)
    }
}
