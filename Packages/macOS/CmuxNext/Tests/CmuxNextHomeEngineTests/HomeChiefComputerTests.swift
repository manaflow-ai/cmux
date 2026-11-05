import AppKit
import CmuxNextCloud
@testable import CmuxNextHomeEngine
import Observation
import Testing

/// The Chief Settings card's Computer section (cmux issue 31488): shown only with a paid plan and
/// a machine that has run, the running machine's screen streams only while the card is open, and
/// a paused machine shows asleep with no stream.
@MainActor @Suite(.serialized) struct HomeChiefComputerTests {
    @Test func theSectionNeedsAPaidPlanAndAMachineThatRan() {
        let paused = CloudMachine(id: "vm-1", status: .paused)
        #expect(HomeChiefComputer(machines: [paused], paid: false) == nil)
        #expect(HomeChiefComputer(machines: [CloudMachine(id: "vm-1", status: .provisioning)], paid: true) == nil)
        #expect(HomeChiefComputer(machines: [], paid: true) == nil)
        // Gone or going machines never count.
        #expect(HomeChiefComputer(machines: [CloudMachine(id: "vm-1", status: .deleting)], paid: true) == nil)
        #expect(HomeChiefComputer(machines: [paused], paid: true) == HomeChiefComputer(machineID: "vm-1", name: "vm-1", state: .asleep))
    }

    @Test func theRunningMachineComesFirstThenTheFirstThatRan() {
        let machines = [CloudMachine(id: "new", status: .provisioning), CloudMachine(id: "old", status: .paused),
                        CloudMachine(id: "up", status: .running)]
        #expect(HomeChiefComputer(machines: machines, paid: true)?.machineID == "up")
        #expect(HomeChiefComputer(machines: Array(machines.prefix(2)), paid: true)?.machineID == "old")
        #expect(HomeChiefComputer(machines: [CloudMachine(id: "vm", status: .starting)], paid: true)?.state == .waking)
        var pausing = CloudMachine(id: "vm", status: .running)
        pausing.pendingChange = .pausing
        #expect(HomeChiefComputer(machines: [pausing], paid: true)?.state == .asleep)
    }

    @Test func aRunningMachineStreamsOnlyWhileTheCardIsOpen() async {
        let rig = Rig(machines: [CloudMachine(id: "vm", status: .running)])
        #expect(rig.section.isHidden)
        rig.section.open()
        // The first state applies in open's own turn, so the card is measured with the section shown.
        #expect(rig.section.streaming == "vm")
        #expect(!rig.section.isHidden)
        #expect(rig.feed.starts == ["vm"])
        rig.section.close()
        #expect(rig.section.streaming == nil)
        #expect(rig.feed.stops == 1)
    }

    @Test func aPausedMachineStopsTheStreamAndShowsAsleep() async {
        let rig = Rig(machines: [CloudMachine(id: "vm", status: .running)])
        rig.section.open()
        await until { rig.section.streaming == "vm" }
        rig.directory.machines = [CloudMachine(id: "vm", status: .paused)]
        await until { rig.section.shown?.state == .asleep }
        #expect(rig.section.streaming == nil)
        #expect(rig.feed.stops == 1)
        // Started again: it streams again.
        rig.directory.machines = [CloudMachine(id: "vm", status: .running)]
        await until { rig.section.streaming == "vm" }
        #expect(rig.feed.starts == ["vm", "vm"])
        rig.section.close()
    }

    @Test func noPaidPlanHidesTheSectionAndStreamsNothing() async {
        let rig = Rig(machines: [CloudMachine(id: "vm", status: .running)], paid: false)
        rig.section.open()
        await until { rig.section.shown == nil && rig.feed.starts.isEmpty }
        #expect(rig.section.isHidden)
        rig.directory.paid = true
        await until { rig.section.streaming == "vm" }
        #expect(!rig.section.isHidden)
        rig.section.close()
    }

    @Test func anEndedStreamIsNotRetriedUntilTheMachineChanges() async {
        let rig = Rig(machines: [CloudMachine(id: "vm", status: .running)])
        rig.section.open()
        await until { rig.section.streaming == "vm" }
        rig.feed.end()
        #expect(rig.section.streaming == nil)
        // A new value for the same machine, still running (renamed), does not reconnect.
        var renamed = CloudMachine(id: "vm", status: .running)
        renamed.displayName = "renamed"
        rig.directory.machines = [renamed]
        await until { rig.section.shown?.name == "renamed" }
        #expect(rig.feed.starts == ["vm"])
        #expect(rig.section.streaming == nil)
        rig.section.close()
        // A new open tries again.
        rig.section.open()
        await until { rig.section.streaming == "vm" }
        #expect(rig.feed.starts == ["vm", "vm"])
        rig.section.close()
    }

    @Test func anUnreachableDesktopShowsUnavailableWithoutAStream() async {
        let rig = Rig(machines: [CloudMachine(id: "vm", status: .running)], reachable: false)
        rig.section.open()
        await until { rig.section.shown != nil }
        #expect(rig.section.streaming == nil)
        #expect(!rig.section.isHidden)
        rig.section.close()
    }

    // MARK: Rig

    @Observable @MainActor final class Directory {
        var paid: Bool
        var machines: [CloudMachine]
        init(paid: Bool, machines: [CloudMachine]) {
            self.paid = paid
            self.machines = machines
        }
    }

    @MainActor final class Feed {
        var starts: [String] = []
        var stops = 0
        var reachable = true
        private var ended: (@MainActor () -> Void)?

        func start(_ id: String, _ ended: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)? {
            guard reachable else { return nil }
            starts.append(id)
            self.ended = ended
            return { [weak self] in
                self?.stops += 1
                self?.ended = nil
            }
        }

        /// The stream ends by itself.
        func end() {
            let ended = ended
            self.ended = nil
            ended?()
        }
    }

    @MainActor struct Rig {
        let directory: Directory
        let feed = Feed()
        let section = HomeChiefComputerSection()

        init(machines: [CloudMachine], paid: Bool = true, reachable: Bool = true) {
            let directory = Directory(paid: paid, machines: machines)
            self.directory = directory
            feed.reachable = reachable
            let feed = feed
            section.source = .init(directory: { (directory.paid, directory.machines) },
                                   frames: { id, _, ended in feed.start(id, ended) })
        }
    }

    /// Lets the section's observation catch up: a bounded number of turns, no clock.
    private func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
        #expect(condition())
    }
}
