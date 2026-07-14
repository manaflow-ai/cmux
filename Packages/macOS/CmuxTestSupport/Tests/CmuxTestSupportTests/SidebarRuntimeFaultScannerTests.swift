import Testing
@testable import CmuxTestSupport

@Suite struct SidebarRuntimeFaultScannerTests {
    @Test(arguments: SidebarRuntimeFaultScanner.signatures)
    func detectsKnownRuntimeFault(_ signature: String) {
        let input = "2026-07-13 15:45:04.001 cmux[9255] \(signature)"

        #expect(
            SidebarRuntimeFaultScanner().faults(in: input) == [
                SidebarRuntimeFaultScanner.Fault(signature: signature, line: input),
            ]
        )
    }

    @Test func ignoresUnrelatedRuntimeMessages() {
        let input = "2026-07-13 15:45:04.001 cmux[9255] sidebar snapshot applied"

        #expect(SidebarRuntimeFaultScanner().faults(in: input).isEmpty)
    }

    @Test func preservesSourceOrderAcrossCombinedLogs() {
        let first = SidebarRuntimeFaultScanner.signatures[1]
        let second = SidebarRuntimeFaultScanner.signatures[0]
        let input = "first: \(first)\nnoise\nsecond: \(second)"

        #expect(
            SidebarRuntimeFaultScanner().faults(in: input).map(\.signature) == [first, second]
        )
    }
}
