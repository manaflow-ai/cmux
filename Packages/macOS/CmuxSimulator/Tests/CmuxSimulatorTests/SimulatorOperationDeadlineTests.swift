import Testing

@testable import CmuxSimulator

@Suite("Simulator operation deadlines")
struct SimulatorOperationDeadlineTests {
    @Test("Semantic UI receipts include cold-device readiness")
    func semanticUIReceiptsIncludeReadiness() {
        let deadlines = SimulatorOperationDeadlines(
            selectDevice: 90,
            inspectionRead: 35,
            uiAutomationAction: 140,
            clientReceiptMargin: 10
        )

        #expect(deadlines.inspectionRead == 125)
        #expect(deadlines.uiAutomationAction == 230)
        #expect(
            deadlines.clientTimeout(for: deadlines.inspectionRead) == 135
        )
        #expect(
            deadlines.clientTimeout(for: deadlines.uiAutomationAction) == 240
        )
    }

    @Test("Semantic UI wait client deadlines match their server receipts")
    func semanticUIWaitClientDeadlineMatchesServerReceipt() {
        let deadlines = SimulatorOperationDeadlines(
            selectDevice: 90,
            clientReceiptMargin: 10
        )

        let receiptTimeout = deadlines.uiWaitReceiptTimeout(
            timeoutMilliseconds: 120_000
        )

        #expect(receiptTimeout == 245)
        #expect(deadlines.clientTimeout(for: receiptTimeout) == 255)
    }
}
