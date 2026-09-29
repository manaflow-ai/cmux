import Foundation
import Testing
@testable import CmuxCloud

struct CloudVMNotFoundTests {
    @Test("Only the typed missing-machine response is terminal")
    func missingMachineClassification() {
        let missing = CloudVMHTTPError(status: 404, body: #"{"error":"vm_not_found"}"#)
        let temporary = CloudVMHTTPError(status: 503, body: #"{"error":"vm_cloud_service_unavailable","retryable":true}"#)
        let otherNotFound = CloudVMHTTPError(status: 404, body: #"{"error":"workspace_not_found"}"#)

        #expect(missing.isMachineNotFound)
        #expect(!temporary.isMachineNotFound)
        #expect(!otherNotFound.isMachineNotFound)
    }

    @Test("Only vm_not_found stops automatic reconnect")
    func reconnectDispositionKeepsTemporaryFailuresRetryable() {
        #expect(CloudMachineLinkManager.shouldStopAutomaticReconnect(
            VMClientError.httpStatus(404, #"{"error":"vm_not_found"}"#)
        ))
        #expect(!CloudMachineLinkManager.shouldStopAutomaticReconnect(
            VMClientError.httpStatus(503, #"{"error":"vm_cloud_service_unavailable","retryable":true}"#)
        ))
    }
}
