import Foundation
import Testing
@testable import CmuxMobileChief

/// Chief info's Computer card (https://github.com/manaflow-ai/cmux/issues/31488):
/// the gate, which machine it shows, and its state from the Cloud status.
@Suite struct ChiefComputerTests {
    typealias Machine = ChiefComputerDirectory.Machine

    func machine(_ id: String, _ status: String?, ran: Bool) -> Machine {
        Machine(machineID: id, teamID: "team", name: "Box \(id)", status: status, ran: ran)
    }

    @Test func hiddenUnlessPaidAndSomeMachineRan() {
        let ran = machine("a", "paused", ran: true)
        let never = machine("b", "provisioning", ran: false)
        #expect(ChiefComputerDirectory(paid: true, machines: [never, ran]).showsComputer)
        #expect(!ChiefComputerDirectory(paid: false, machines: [ran]).showsComputer)
        #expect(!ChiefComputerDirectory(paid: true, machines: [never]).showsComputer)
        #expect(!ChiefComputerDirectory(paid: true, machines: []).showsComputer)
        // The Mac's owner has not turned on phone.cloudDesktop: no card.
        #expect(!ChiefComputerDirectory(paid: true, desktops: false, machines: [ran]).showsComputer)
        #expect(ChiefComputerDirectory(paid: false, machines: [ran]).computer == nil)
    }

    @Test func picksTheFirstRunningElseTheFirstThatRan() {
        let paused = machine("a", "paused", ran: true)
        let never = machine("b", "failed", ran: false)
        let running = machine("c", "running", ran: true)
        let later = machine("d", "running", ran: true)
        #expect(ChiefComputerDirectory(paid: true, machines: [paused, never, running, later]).computer == running)
        #expect(ChiefComputerDirectory(paid: true, machines: [never, paused]).computer == paused)
    }

    @Test func mapsCloudStatusToTheCardState() {
        #expect(ChiefComputerState(status: "running") == .live)
        #expect(ChiefComputerState(status: "paused") == .asleep)
        #expect(ChiefComputerState(status: "pausing") == .asleep)
        #expect(ChiefComputerState(status: "starting") == .waking)
        #expect(ChiefComputerState(status: "provisioning") == .waking)
        for status in ["failed", "unknown", "destroyed", "deleting", "something-new", nil] as [String?] {
            #expect(ChiefComputerState(status: status) == .unavailable, "\(status ?? "nil")")
        }
    }

    @Test func anAsleepRefusalShowsAsleepAndATransientCloseDoesNot() {
        #expect(ChiefComputerState.live.refused("asleep") == .asleep)
        #expect(ChiefComputerState.live.refused("forbidden") == .unavailable)
        #expect(ChiefComputerState.live.refused("no_surface_host") == .unavailable)
        for code in ["eof", "stalled", "evicted", "replaced", "timeout", "no-link"] {
            #expect(ChiefComputerState.live.refused(code) == .live, "\(code)")
        }
        #expect(ChiefComputerState.live.refused(nil) == .live)
        #expect(ChiefComputerState.waking.refused("asleep") == .waking)
    }

    @Test func aRunningMachineOnAMacWithoutDesktopStreamingIsUnavailable() throws {
        let directory = ChiefComputerDirectory(paid: true, machines: [machine("a", "running", ran: true)])
        let old = try #require(ChiefComputer.shown(directory, mac: ChiefComputerMac(macID: "mac", streamsDesktop: false)))
        #expect(old.state == .unavailable)
        let new = try #require(ChiefComputer.shown(directory, mac: ChiefComputerMac(macID: "mac", streamsDesktop: true)))
        #expect(new.state == .live)
        #expect(new.macID == "mac")
        #expect(new.machine.machineID == "a")
    }
}

/// The card loads from its source and hides when there is no Mac or the read fails.
@MainActor @Suite struct ChiefComputerLoadTests {
    final class Source: ChiefComputerSource {
        var mac: ChiefComputerMac?
        var directory: Result<ChiefComputerDirectory, any Error>
        var asked: [String?] = []
        init(mac: ChiefComputerMac?, directory: Result<ChiefComputerDirectory, any Error>) {
            self.mac = mac
            self.directory = directory
        }
        func computerMac(preferring preferred: String?) -> ChiefComputerMac? {
            asked.append(preferred)
            return mac
        }
        func computerDirectory(on macID: String) async throws -> ChiefComputerDirectory { try directory.get() }
    }

    struct Down: Error {}

    let paused = ChiefComputerDirectory(paid: true, machines: [
        .init(machineID: "m", teamID: "t", name: "Dev box", status: "paused", ran: true),
    ])

    @Test func showsTheMachineAndHidesWhenTheMacGoes() async {
        let computer = ChiefComputer()
        let source = Source(mac: ChiefComputerMac(macID: "mac", streamsDesktop: true), directory: .success(paused))
        computer.source = source
        await computer.load(preferring: "chief-mac")
        #expect(source.asked == ["chief-mac"])
        #expect(computer.shown?.machine.name == "Dev box")
        #expect(computer.state == .asleep)
        #expect(computer.stream == nil)

        source.mac = nil
        await computer.load(preferring: "chief-mac")
        #expect(computer.shown == nil)
    }

    @Test func aFailedReadHidesTheCard() async {
        let computer = ChiefComputer()
        let source = Source(mac: ChiefComputerMac(macID: "mac", streamsDesktop: true), directory: .success(paused))
        computer.source = source
        await computer.load(preferring: nil)
        #expect(computer.shown != nil)
        source.directory = .failure(Down())
        await computer.load(preferring: nil)
        #expect(computer.shown == nil)
    }

    @Test func aMacChangeAsksForAReload() {
        let computer = ChiefComputer()
        let before = computer.reload(preferring: "mac")
        computer.macChanged()
        #expect(computer.reload(preferring: "mac") != before)
        #expect(computer.reload(preferring: "mac") == computer.reload(preferring: "mac"))
    }

    @Test func noSourceHidesTheCard() async {
        let computer = ChiefComputer()
        await computer.load(preferring: "mac")
        #expect(computer.shown == nil)
    }
}
