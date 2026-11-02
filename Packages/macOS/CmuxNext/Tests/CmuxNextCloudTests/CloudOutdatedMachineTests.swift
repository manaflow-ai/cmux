import CmuxNextCloud
import Testing

@Suite
@MainActor
struct CloudOutdatedMachineTests {
    @Test func anOutdatedMachineUpdatesBeforeItsCapabilityIsUsed() async {
        var handshake = "old"
        var holdsTabs = false
        var updates = 0

        await CloudOutdatedMachine.updateBeforeUsingCapability(
            holds: { holdsTabs },
            link: { handshake },
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
            link: { "old" },
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
            link: { "current" },
            relink: .milliseconds(10),
            update: {
                updates += 1
                return true
            })

        #expect(updates == 0)
    }
}
