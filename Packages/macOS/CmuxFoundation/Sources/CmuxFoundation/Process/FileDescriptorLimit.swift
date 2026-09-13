import Darwin

/// Darwin `RLIM_INFINITY` (`((1 << 63) - 1)`). The C macro is not imported into Swift.
private let rlimitInfinity: UInt64 = (UInt64(1) << 63) - 1

/// Raises the process `RLIMIT_NOFILE` soft limit so GUI-launched children
/// are not stuck on launchd's default of 256.
///
/// macOS GUI apps inherit `launchctl limit maxfiles` soft=256. cmux then
/// spawns login shells (`/usr/bin/login -flp …`) and coding agents; those
/// children inherit the ceiling. Codex and similar CLIs open many
/// `SKILL.md` files at startup and fail with `EMFILE` ("Too many open
/// files (os error 24)"). `login` does not raise the limit; it inherits.
///
/// Call from `CmuxMain.main()` before any worker re-exec or child spawn so
/// every re-exec of this binary, and every descendant, inherits the higher
/// soft limit. Never lowers an existing limit, never changes the hard
/// limit, and ignores `setrlimit` failure.
public enum FileDescriptorLimit {
    /// Soft floor requested at process start. The hard limit is left untouched.
    public static let preferredSoftLimit: UInt64 = 65_536

    /// Darwin historically rejected `setrlimit` above `OPEN_MAX` (10240).
    /// Try the preferred floor first, then these fallbacks.
    static let fallbackSoftLimits: [UInt64] = [10_240, 8_192]

    /// Returns the soft limit to apply, or `nil` when the current pair is
    /// already sufficient or cannot be raised without changing the hard limit.
    public static func proposedSoftLimit(
        currentSoft: UInt64,
        hardLimit: UInt64,
        target: UInt64 = preferredSoftLimit
    ) -> UInt64? {
        if currentSoft == rlimitInfinity {
            return nil
        }
        let ceiling = hardLimit == rlimitInfinity ? target : min(target, hardLimit)
        if currentSoft >= ceiling {
            return nil
        }
        return ceiling
    }

    /// Best-effort raise of `RLIMIT_NOFILE`. Safe to call more than once.
    public static func raiseSoftLimitIfNeeded() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }

        let currentSoft = UInt64(limit.rlim_cur)
        let hardLimit = UInt64(limit.rlim_max)
        let targets = [preferredSoftLimit] + fallbackSoftLimits

        for target in targets {
            guard let newSoft = proposedSoftLimit(
                currentSoft: currentSoft,
                hardLimit: hardLimit,
                target: target
            ) else {
                continue
            }
            var updated = limit
            updated.rlim_cur = rlim_t(newSoft)
            if setrlimit(RLIMIT_NOFILE, &updated) == 0 {
                return
            }
        }
    }
}
