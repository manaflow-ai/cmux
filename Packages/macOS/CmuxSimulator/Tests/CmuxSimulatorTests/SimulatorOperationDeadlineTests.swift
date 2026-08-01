import Testing

@testable import CmuxSimulator

@Suite("Simulator operation deadlines")
struct SimulatorOperationDeadlineTests {
    @Test("Semantic UI actions cover the server receipt deadline")
    func semanticUIActionClientTimeout() {
        let deadlines = SimulatorOperationDeadlines(clientReceiptMargin: 10)

        #expect(deadlines.uiAutomationAction == 140)
        #expect(
            deadlines.clientTimeout(for: deadlines.uiAutomationAction) == 150
        )
    }
}
