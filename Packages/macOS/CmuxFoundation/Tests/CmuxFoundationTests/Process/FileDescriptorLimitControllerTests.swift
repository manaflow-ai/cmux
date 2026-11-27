import Darwin
import Testing

import CmuxFoundation

@Suite("File descriptor limit controller")
struct FileDescriptorLimitControllerTests {
    /// Darwin's `RLIM_INFINITY` macro is not imported into Swift.
    private let unlimited = rlim_t(Int64.max)

    /// Verifies that low inherited limits are raised to the preferred target.
    @Test("Raises low inherited limits", arguments: [rlim_t(256), 8_192])
    func raisesLowInheritedLimits(soft: rlim_t) {
        let system = FileDescriptorLimitSystemStub(soft: soft, hard: unlimited)
        let controller = FileDescriptorLimitController(
            readLimit: system.readLimit,
            writeLimit: system.writeLimit
        )

        controller.raiseSoftLimitIfNeeded()

        #expect(system.limits?.rlim_cur == 65_536)
        #expect(system.limits?.rlim_max == unlimited)
        #expect(system.attemptedLimits.count == 1)
    }

    /// Verifies that sufficient and unlimited soft limits are left untouched.
    @Test("Never lowers sufficient or unlimited limits", arguments: [rlim_t(65_536), 100_000, rlim_t(Int64.max)])
    func leavesSufficientLimitsAlone(soft: rlim_t) {
        let system = FileDescriptorLimitSystemStub(soft: soft, hard: unlimited)
        FileDescriptorLimitController(
            readLimit: system.readLimit,
            writeLimit: system.writeLimit
        ).raiseSoftLimitIfNeeded()

        #expect(system.attemptedLimits.isEmpty)
        #expect(system.limits?.rlim_cur == soft)
    }

    /// Verifies that a finite hard limit caps the requested soft limit.
    @Test("Clamps to finite hard limits", arguments: [rlim_t(512), 8_192, 10_240])
    func respectsFiniteHardLimits(hard: rlim_t) {
        let system = FileDescriptorLimitSystemStub(soft: 256, hard: hard)
        FileDescriptorLimitController(
            readLimit: system.readLimit,
            writeLimit: system.writeLimit
        ).raiseSoftLimitIfNeeded()

        #expect(system.limits?.rlim_cur == hard)
        #expect(system.limits?.rlim_max == hard)
        #expect(system.attemptedLimits.count == 1)
    }

    /// Verifies that a soft limit already at its hard ceiling is unchanged.
    @Test("Does not change an exhausted hard limit", arguments: [rlim_t(0), 256, 8_192])
    func leavesExhaustedHardLimitsAlone(hard: rlim_t) {
        let system = FileDescriptorLimitSystemStub(soft: hard, hard: hard)
        FileDescriptorLimitController(
            readLimit: system.readLimit,
            writeLimit: system.writeLimit
        ).raiseSoftLimitIfNeeded()

        #expect(system.attemptedLimits.isEmpty)
    }

    /// Verifies that rejected targets are retried in configured order.
    @Test("Stops at the first accepted target", arguments: [
        (rlim_t(65_536), [rlim_t(65_536)]),
        (rlim_t(10_240), [rlim_t(65_536), 10_240]),
        (rlim_t(8_192), [rlim_t(65_536), 10_240, 8_192])
    ])
    func retriesRejectedTargets(maximumAccepted: rlim_t, expectedAttempts: [rlim_t]) {
        let system = FileDescriptorLimitSystemStub(
            soft: 256,
            hard: unlimited,
            maximumAcceptedSoftLimit: maximumAccepted
        )
        FileDescriptorLimitController(
            readLimit: system.readLimit,
            writeLimit: system.writeLimit
        ).raiseSoftLimitIfNeeded()

        #expect(system.attemptedLimits.map(\.rlim_cur) == expectedAttempts)
        #expect(system.attemptedLimits.allSatisfy { $0.rlim_max == unlimited })
        #expect(system.limits?.rlim_cur == maximumAccepted)
    }

    /// Verifies that a failed resource-limit read does not attempt a write.
    @Test("Ignores a failed limits read")
    func ignoresReadFailure() {
        let system = FileDescriptorLimitSystemStub(soft: nil)
        FileDescriptorLimitController(
            readLimit: system.readLimit,
            writeLimit: system.writeLimit
        ).raiseSoftLimitIfNeeded()

        #expect(system.readCount == 1)
        #expect(system.attemptedLimits.isEmpty)
    }

    /// Verifies that failed writes do not mutate the supplied limits snapshot.
    @Test("Leaves the original pair intact when all writes fail")
    func ignoresWriteFailures() {
        let system = FileDescriptorLimitSystemStub(
            soft: 256,
            hard: unlimited,
            maximumAcceptedSoftLimit: nil
        )
        FileDescriptorLimitController(
            readLimit: system.readLimit,
            writeLimit: system.writeLimit
        ).raiseSoftLimitIfNeeded()

        #expect(system.attemptedLimits.map(\.rlim_cur) == [65_536, 10_240, 8_192])
        #expect(system.attemptedLimits.allSatisfy { $0.rlim_max == unlimited })
        #expect(system.limits?.rlim_cur == 256)
        #expect(system.limits?.rlim_max == unlimited)
    }

    /// Verifies that fallback targets below the inherited soft limit are skipped.
    @Test("Rejected raises never fall back below the inherited soft limit")
    func skipsLowerFallbacks() {
        let system = FileDescriptorLimitSystemStub(
            soft: 20_000,
            hard: unlimited,
            maximumAcceptedSoftLimit: nil
        )
        FileDescriptorLimitController(
            readLimit: system.readLimit,
            writeLimit: system.writeLimit
        ).raiseSoftLimitIfNeeded()

        #expect(system.attemptedLimits.map(\.rlim_cur) == [65_536])
        #expect(system.limits?.rlim_cur == 20_000)
    }

    /// Verifies that callers can provide a custom preferred and fallback policy.
    @Test("Uses injected limit configuration")
    func usesConfiguredTargets() {
        let system = FileDescriptorLimitSystemStub(
            soft: 256,
            hard: unlimited,
            maximumAcceptedSoftLimit: 15_000
        )
        FileDescriptorLimitController(
            preferredSoftLimit: 20_000,
            fallbackSoftLimits: [15_000],
            readLimit: system.readLimit,
            writeLimit: system.writeLimit
        ).raiseSoftLimitIfNeeded()

        #expect(system.attemptedLimits.map(\.rlim_cur) == [20_000, 15_000])
        #expect(system.limits?.rlim_cur == 15_000)
    }

    /// Verifies that a second invocation is idempotent after a successful raise.
    @Test("A repeated invocation reads the raised limit without rewriting it")
    func doesNotRewriteSufficientLimit() {
        let system = FileDescriptorLimitSystemStub(soft: 256, hard: unlimited)
        let controller = FileDescriptorLimitController(
            readLimit: system.readLimit,
            writeLimit: system.writeLimit
        )

        controller.raiseSoftLimitIfNeeded()
        controller.raiseSoftLimitIfNeeded()

        #expect(system.readCount == 2)
        #expect(system.attemptedLimits.count == 1)
        #expect(system.limits?.rlim_cur == 65_536)
    }
}
