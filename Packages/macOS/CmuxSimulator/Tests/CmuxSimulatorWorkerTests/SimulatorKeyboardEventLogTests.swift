import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator keyboard event-log privacy")
struct SimulatorKeyboardEventLogTests {
    private let eventLog = SimulatorKeyboardEventLog()
    @Test("Printable keyboard and keypad usages have one indistinguishable label")
    func printableUsagesAreRedacted() {
        let printableUsages: [UInt32] = [
            0x04, 0x1D,
            0x1E, 0x27,
            0x2C, 0x38,
            0x54, 0x57,
            0x59, 0x63,
            0x64, 0x67,
        ]

        for usage in printableUsages {
            #expect(eventLog.isPrintable(usage))
            #expect(eventLog.summary(for: usage) == "character")
        }
    }

    @Test("A password cannot be reconstructed from keyboard action summaries")
    func passwordSequenceCannotBeReconstructed() {
        let firstPassword: [UInt32] = [
            0x0B, 0x18, 0x11, 0x17, 0x08, 0x15, 0x1F, 0x1E,
        ]
        let secondPassword: [UInt32] = [
            0x16, 0x08, 0x06, 0x15, 0x08, 0x17, 0x26, 0x38,
        ]

        let firstLog = firstPassword.map(eventLog.summary(for:))
        let secondLog = secondPassword.map(eventLog.summary(for:))

        #expect(firstLog == secondLog)
        #expect(firstLog == Array(repeating: "character", count: firstPassword.count))
        #expect(firstLog.joined(separator: " ").contains("0x") == false)
    }

    @Test("Non-printable controls retain readable labels without raw usages")
    func controlsRetainLabels() {
        #expect(eventLog.summary(for: 0x28) == "Enter")
        #expect(eventLog.summary(for: 0x50) == "ArrowLeft")
        #expect(eventLog.summary(for: 0xE3) == "CommandLeft")
        #expect(eventLog.summary(for: 0xFFFF) == "control")
    }
}
