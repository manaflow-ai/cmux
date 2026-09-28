import Foundation
import Testing
@testable import CmuxCloud

struct CloudVMErrorContractTests {
    @Test("recreate-required responses explain the terminal machine state")
    func recreateRequiredResponseUsesTerminalCopy() {
        let body = #"{"error":"vm_requires_recreate","retryable":false}"#
        let text = formattedCloudVMHTTPError(status: 409, body: body)

        #expect(text.contains("This machine needs to be recreated"))
        #expect(!text.contains("Cloud service unavailable"))
    }
}
