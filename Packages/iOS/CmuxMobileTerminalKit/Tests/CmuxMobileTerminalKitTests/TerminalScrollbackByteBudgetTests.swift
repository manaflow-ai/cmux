import Testing
@testable import CmuxMobileTerminalKit

@Suite("TerminalScrollbackByteBudget")
struct TerminalScrollbackByteBudgetTests {
    private let gibibyte: UInt64 = 1 << 30

    @Test("4GB and larger devices keep the historical 16MB limit")
    func largeDevicesKeepHistoricalCeiling() {
        for memory in [4 * gibibyte, 6 * gibibyte, 8 * gibibyte, 16 * gibibyte] {
            #expect(
                TerminalScrollbackByteBudget.scrollbackLimitBytes(
                    physicalMemoryBytes: memory
                ) == TerminalScrollbackByteBudget.ceilingBytes
            )
        }
    }

    @Test("a 3GB device (iPad12,1, the top jetsam device) is budgeted below the ceiling")
    func threeGigabyteDeviceScalesDown() {
        let budget = TerminalScrollbackByteBudget.scrollbackLimitBytes(
            physicalMemoryBytes: 3 * gibibyte
        )
        #expect(budget == 3 * gibibyte / 256)
        #expect(budget < TerminalScrollbackByteBudget.ceilingBytes)
        #expect(budget > TerminalScrollbackByteBudget.floorBytes)
    }

    @Test("small devices never drop below the replay-window floor")
    func smallDevicesKeepReplayWindowFloor() {
        for memory in [UInt64(0), gibibyte, 2 * gibibyte - (1 << 27)] {
            #expect(
                TerminalScrollbackByteBudget.scrollbackLimitBytes(
                    physicalMemoryBytes: memory
                ) == TerminalScrollbackByteBudget.floorBytes
            )
        }
    }

    @Test("the budget is monotonic in physical memory")
    func budgetIsMonotonic() {
        let samples = stride(from: UInt64(0), through: 8 * gibibyte, by: 1 << 28)
        var previous: UInt64 = 0
        for memory in samples {
            let budget = TerminalScrollbackByteBudget.scrollbackLimitBytes(
                physicalMemoryBytes: memory
            )
            #expect(budget >= previous)
            #expect(budget >= TerminalScrollbackByteBudget.floorBytes)
            #expect(budget <= TerminalScrollbackByteBudget.ceilingBytes)
            previous = budget
        }
    }
}
