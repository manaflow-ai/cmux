import CmuxCloud
import Foundation
import Testing

@Suite("Cloud link retry backoff")
struct CloudLinkRetryBackoffTests {
    private let failedAt = Date(timeIntervalSince1970: 1_000)

    @Test("background upkeep waits out the backoff after a failure")
    func upkeepWaits() async {
        await CloudMachineLinkManager.$isBackgroundUpkeep.withValue(true) {
            #expect(CloudMachineLinkManager.backoffRejects(failedAt: failedAt, now: failedAt.addingTimeInterval(5), backoff: 15))
            #expect(!CloudMachineLinkManager.backoffRejects(failedAt: failedAt, now: failedAt.addingTimeInterval(16), backoff: 15))
        }
    }

    @Test("anything a person or an agent asked for dials inside the backoff")
    func requestsDial() {
        #expect(!CloudMachineLinkManager.isBackgroundUpkeep)
        #expect(!CloudMachineLinkManager.backoffRejects(failedAt: failedAt, now: failedAt.addingTimeInterval(1), backoff: 15))
    }

    @Test("work started by upkeep inherits the mark")
    func childTasksInherit() async {
        let inherited = await CloudMachineLinkManager.$isBackgroundUpkeep.withValue(true) {
            await Task { CloudMachineLinkManager.isBackgroundUpkeep }.value
        }
        #expect(inherited)
    }
}
