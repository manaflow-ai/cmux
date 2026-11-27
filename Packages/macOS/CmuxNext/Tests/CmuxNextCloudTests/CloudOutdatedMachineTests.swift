import CmuxNextCloud
import Observation
import Testing

/// A machine whose new link comes up before its handshake carries the capability.
@Observable @MainActor
private final class Relinking {
    var holdsTabs = false
}

@Suite
@MainActor
struct CloudOutdatedMachineTests {
    @Test func anOutdatedMachineUpdatesBeforeItsCapabilityIsUsed() async {
        var handshake = "old"
        var holdsTabs = false
        var updates = 0

        await CloudOutdatedMachine.updateBeforeUsingCapability(
            holds: { holdsTabs },
            relink: .seconds(1),
            update: {
                updates += 1
                await Task.yield()
                handshake = "new"
                holdsTabs = true
                return true
            })

        #expect(updates == 1)
        #expect(handshake == "new")
        #expect(holdsTabs)
    }

    @Test func anUpdateThatDoesNotRelinkReturnsWithinTheBoundedWait() async {
        var holdsTabs = false
        var updates = 0

        await CloudOutdatedMachine.updateBeforeUsingCapability(
            holds: { holdsTabs },
            relink: .milliseconds(10),
            update: {
                updates += 1
                return true
            })

        #expect(updates == 1)
        #expect(!holdsTabs)
    }

    @Test func anAlreadyCurrentMachineDoesNotUpdate() async {
        var updates = 0

        await CloudOutdatedMachine.updateBeforeUsingCapability(
            holds: { true },
            relink: .milliseconds(10),
            update: {
                updates += 1
                return true
            })

        #expect(updates == 0)
    }

    @Test func aNewLinkWithoutTheCapabilityYetIsWaitedFor() async {
        let machine = Relinking()

        await CloudOutdatedMachine.updateBeforeUsingCapability(
            holds: { machine.holdsTabs },
            relink: .seconds(5),
            update: {
                // The link changed already; the capability arrives with the handshake a turn later.
                Task { @MainActor in machine.holdsTabs = true }
                return true
            })

        #expect(machine.holdsTabs)
    }
}
