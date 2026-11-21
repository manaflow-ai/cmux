@testable import CmuxNextPages
import Testing

/// The Cloud page's confirmed ops a person's own click runs with no sheet (``PageConfirmation/clickRunsOps``):
/// sign in or out, billing, connect and restore. Every delete still asks on the sheet.
@Suite struct CloudPageClickOpsTests {
    @Test func clickOpsAreCloudPageConfirmedOps() {
        let confirmed = Set(PageDescriptor.cloud.confirmedOps.keys)
        #expect(PageConfirmation.clickRunsOps.isSubset(of: confirmed), "a click op the page reaches only through action.run")
    }

    @Test func deletesAlwaysAsk() {
        let deletes = PageDescriptor.cloud.confirmedOps.filter { $0.value == .delete }.map(\.key)
        #expect(!deletes.isEmpty)
        for op in deletes { #expect(!PageConfirmation.clickRunsOps.contains(op), "\(op) removes something for good") }
    }
}
