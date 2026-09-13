import Testing

@testable import CmuxFoundation

@Suite("File descriptor limit")
struct FileDescriptorLimitTests {
    /// Darwin `RLIM_INFINITY`.
    private let unlimited: UInt64 = (UInt64(1) << 63) - 1

    @Test("Raises launchd's default 256 toward the preferred floor when hard is unlimited")
    func raisesDefaultSoftWhenHardIsUnlimited() {
        #expect(
            FileDescriptorLimit.proposedSoftLimit(currentSoft: 256, hardLimit: unlimited)
                == FileDescriptorLimit.preferredSoftLimit
        )
    }

    @Test("Raises an already-bumped but still-low soft limit")
    func raisesIntermediateSoftLimit() {
        #expect(
            FileDescriptorLimit.proposedSoftLimit(currentSoft: 8_192, hardLimit: unlimited)
                == FileDescriptorLimit.preferredSoftLimit
        )
    }

    @Test("Does not lower a soft limit already at or above the target")
    func doesNotLowerExistingSoftLimit() {
        #expect(
            FileDescriptorLimit.proposedSoftLimit(
                currentSoft: FileDescriptorLimit.preferredSoftLimit,
                hardLimit: unlimited
            ) == nil
        )
        #expect(
            FileDescriptorLimit.proposedSoftLimit(currentSoft: 100_000, hardLimit: unlimited)
                == nil
        )
    }

    @Test("Never proposes a soft limit above the hard limit")
    func clampsToHardLimit() {
        #expect(
            FileDescriptorLimit.proposedSoftLimit(currentSoft: 256, hardLimit: 10_240)
                == 10_240
        )
        #expect(
            FileDescriptorLimit.proposedSoftLimit(currentSoft: 256, hardLimit: 256)
                == nil
        )
    }

    @Test("Leaves an unlimited soft limit alone")
    func ignoresUnlimitedSoftLimit() {
        #expect(
            FileDescriptorLimit.proposedSoftLimit(currentSoft: unlimited, hardLimit: unlimited)
                == nil
        )
    }

    @Test("OPEN_MAX fallback still raises 256 when preferred is rejected by the ceiling")
    func fallbackTargetStillRaisesLaunchdDefault() {
        #expect(
            FileDescriptorLimit.proposedSoftLimit(
                currentSoft: 256,
                hardLimit: unlimited,
                target: 10_240
            ) == 10_240
        )
    }
}
