public import Darwin

/// Raises the process file-descriptor soft limit before child processes inherit it.
///
/// GUI apps can inherit launchd's low `RLIMIT_NOFILE` soft limit. Construct this
/// controller at process entry and call it before worker routing or child creation.
/// The preferred value is 65,536, with 10,240 and 8,192 fallbacks for Darwin
/// configurations that reject the larger requests. The hard limit is preserved.
///
/// ```swift
/// FileDescriptorLimitController().raiseSoftLimitIfNeeded()
/// ```
public struct FileDescriptorLimitController {
    private let softLimitTargets: [rlim_t]
    private let readLimit: () -> rlimit?
    private let writeLimit: (rlimit) -> Bool

    /// Creates a controller with an ordered limit policy and resource-limit operations.
    ///
    /// Construction performs no system calls. Inject both operations to exercise
    /// the policy without changing the process-wide limits in a test host.
    ///
    /// - Parameters:
    ///   - preferredSoftLimit: The first target, defaulting to 65,536 descriptors.
    ///   - fallbackSoftLimits: Targets tried after rejected writes, defaulting to
    ///     10,240 and 8,192 for compatibility with lower Darwin ceilings.
    ///   - readLimit: Reads the current pair, or returns `nil` on failure.
    ///     Defaults to `getrlimit(RLIMIT_NOFILE, ...)`.
    ///   - writeLimit: Applies a pair and reports success. Defaults to
    ///     `setrlimit(RLIMIT_NOFILE, ...)`; failed writes must leave the pair unchanged.
    public init(
        preferredSoftLimit: rlim_t = 65_536,
        fallbackSoftLimits: [rlim_t] = [10_240, 8_192],
        readLimit: @escaping () -> rlimit? = {
            var limit = rlimit()
            guard Darwin.getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return nil }
            return limit
        },
        writeLimit: @escaping (rlimit) -> Bool = { limit in
            var updated = limit
            return Darwin.setrlimit(RLIMIT_NOFILE, &updated) == 0
        }
    ) {
        self.softLimitTargets = [preferredSoftLimit] + fallbackSoftLimits
        self.readLimit = readLimit
        self.writeLimit = writeLimit
    }

    /// Best-effort raises the soft limit without lowering it or changing the hard limit.
    ///
    /// Read failures leave the limit alone; write failures advance to the next
    /// eligible target. An already-sufficient or unlimited soft limit is unchanged.
    /// Run synchronously before concurrent startup so another writer cannot change
    /// the process-wide limits between the read and write.
    public func raiseSoftLimitIfNeeded() {
        guard let limit = readLimit() else { return }

        for target in softLimitTargets {
            // Darwin's unlimited sentinel exceeds the finite startup targets,
            // so this also preserves unlimited soft and hard limits.
            let newSoftLimit = min(target, limit.rlim_max)
            guard newSoftLimit > limit.rlim_cur else { continue }

            var updated = limit
            updated.rlim_cur = newSoftLimit
            if writeLimit(updated) { return }
        }
    }
}
