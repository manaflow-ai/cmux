import Testing
@testable import CMUXMobileCore

@Suite
struct MobileHostRPCWorkQuotaTests {
    @Test
    func permitsBoundedConcurrencyThenRejectsAnotherRequest() {
        let quota = MobileHostRPCWorkQuota(
            maximumConcurrentRequestCount: 3,
            maximumAggregateFrameByteCount: 100
        )

        #expect(quota.allowsAdmission(
            frameByteCount: 1,
            activeFrameByteCounts: [10, 20]
        ))
        #expect(!quota.allowsAdmission(
            frameByteCount: 1,
            activeFrameByteCounts: [10, 20, 30]
        ))
    }

    @Test
    func boundsAggregateDecodedBytesAcrossConcurrentRequests() {
        let quota = MobileHostRPCWorkQuota(
            maximumConcurrentRequestCount: 10,
            maximumAggregateFrameByteCount: 100
        )

        #expect(quota.allowsAdmission(
            frameByteCount: 40,
            activeFrameByteCounts: [25, 35]
        ))
        #expect(!quota.allowsAdmission(
            frameByteCount: 41,
            activeFrameByteCounts: [25, 35]
        ))
        #expect(!quota.allowsAdmission(
            frameByteCount: 101,
            activeFrameByteCounts: []
        ))
    }

    @Test
    func defaultBudgetAllowsOneMaximumFrameWithoutIntegerOverflow() {
        let quota = MobileHostRPCWorkQuota()

        #expect(quota.allowsAdmission(
            frameByteCount: MobileSyncFrameCodec.defaultMaximumFrameByteCount,
            activeFrameByteCounts: []
        ))
        #expect(!quota.allowsAdmission(
            frameByteCount: 1,
            activeFrameByteCounts: [Int.max]
        ))
    }
}
