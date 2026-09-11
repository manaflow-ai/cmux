import Darwin

/// An in-memory resource-limit system confined to one synchronous test invocation.
final class FileDescriptorLimitSystemStub {
    var limits: rlimit?
    private let maximumAcceptedSoftLimit: rlim_t?
    private(set) var readCount = 0
    private(set) var attemptedLimits: [rlimit] = []

    init(
        soft: rlim_t?,
        hard: rlim_t = rlim_t(Int64.max),
        maximumAcceptedSoftLimit: rlim_t? = rlim_t(Int64.max)
    ) {
        if let soft {
            var limits = rlimit()
            limits.rlim_cur = soft
            limits.rlim_max = hard
            self.limits = limits
        } else {
            self.limits = nil
        }
        self.maximumAcceptedSoftLimit = maximumAcceptedSoftLimit
    }

    func readLimit() -> rlimit? {
        readCount += 1
        return limits
    }

    func writeLimit(_ limit: rlimit) -> Bool {
        attemptedLimits.append(limit)
        guard let maximumAcceptedSoftLimit,
              limit.rlim_cur <= maximumAcceptedSoftLimit else {
            return false
        }
        limits = limit
        return true
    }
}
