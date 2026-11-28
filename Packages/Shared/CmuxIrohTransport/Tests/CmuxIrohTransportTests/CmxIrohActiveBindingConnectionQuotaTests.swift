import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohActiveBindingConnectionQuotaTests {
    private let bindingID = "123e4567-e89b-42d3-a456-426614174001"

    @Test
    func permitsReconnectOverlapThenRejectsAThirdSession() {
        let quota = CmxIrohActiveBindingConnectionQuota()

        #expect(quota.allowsAdmission(
            for: bindingID,
            activeBindingIDs: []
        ))
        #expect(quota.allowsAdmission(
            for: bindingID,
            activeBindingIDs: [bindingID]
        ))
        #expect(!quota.allowsAdmission(
            for: bindingID,
            activeBindingIDs: [bindingID, bindingID]
        ))
    }

    @Test
    func sessionsFromOtherBindingsDoNotConsumeTheQuota() {
        let quota = CmxIrohActiveBindingConnectionQuota()
        let otherBindingID = "123e4567-e89b-42d3-a456-426614174099"

        #expect(quota.allowsAdmission(
            for: bindingID,
            activeBindingIDs: [otherBindingID, otherBindingID, bindingID]
        ))
    }
}
