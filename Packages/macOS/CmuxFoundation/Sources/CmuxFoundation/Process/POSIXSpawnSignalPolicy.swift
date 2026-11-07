public import Darwin

/// The signal state a `posix_spawn` child starts with: no blocked signals and
/// the default disposition for every signal that can be caught.
///
/// A spawned process inherits the calling thread's signal mask and every
/// `SIG_IGN` disposition of the parent. cmux spawns from Swift concurrency and
/// dispatch worker threads, which block nearly every signal, and the app ignores
/// SIGPIPE. Without this policy a child never receives SIGTERM or SIGWINCH and
/// cannot shut down or resize. Every cmux `posix_spawn` call site applies it.
///
/// Foundation `Process` already resets both on macOS, so it needs no policy.
/// A non-interactive `/bin/sh` still starts `&` background jobs with SIGINT
/// and SIGQUIT ignored, whatever this policy set; use `set -m` or exec the
/// target directly when that matters.
///
/// ```swift
/// var attributes: posix_spawnattr_t?
/// posix_spawnattr_init(&attributes)
/// defer { posix_spawnattr_destroy(&attributes) }
/// posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
/// let status = POSIXSpawnSignalPolicy().apply(to: &attributes)
/// guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EINVAL) }
/// ```
public struct POSIXSpawnSignalPolicy: Sendable {
    /// Signals reset to their default disposition in the child.
    ///
    /// Every signal from 1 through `NSIG - 1` except SIGKILL and SIGSTOP, which
    /// cannot be caught or ignored, and except the signals passed to ``init(inheritingDispositionsOf:)``.
    public let defaultedSignals: [Int32]

    /// Creates the policy that clears the mask and defaults every catchable signal.
    ///
    /// - Parameter inheritedDispositions: Signals whose disposition the child
    ///   keeps from this process. Empty by default, the state a shell gives a
    ///   program. Pass `[SIGPIPE]` only where a child must keep the app's ignored
    ///   SIGPIPE, so a closed pipe returns `EPIPE` instead of killing it. The mask
    ///   is cleared for every signal regardless.
    public init(inheritingDispositionsOf inheritedDispositions: Set<Int32> = []) {
        defaultedSignals = (1..<NSIG).filter {
            $0 != SIGKILL && $0 != SIGSTOP && !inheritedDispositions.contains($0)
        }
    }

    /// Configures `attributes` so the child starts with an empty signal mask and
    /// default dispositions.
    ///
    /// Adds `POSIX_SPAWN_SETSIGMASK` and `POSIX_SPAWN_SETSIGDEF` to the flags
    /// already set, so call it after `posix_spawnattr_setflags`. A later
    /// `posix_spawnattr_setflags` call that omits those two flags undoes it.
    ///
    /// - Parameter attributes: Initialized spawn attributes.
    /// - Returns: `0`, or the error number of the first `posix_spawnattr_*`
    ///   call that failed.
    public func apply(to attributes: inout posix_spawnattr_t?) -> Int32 {
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var status = posix_spawnattr_setsigmask(&attributes, &emptyMask)
        guard status == 0 else { return status }

        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signalNumber in defaultedSignals {
            sigaddset(&defaults, signalNumber)
        }
        status = posix_spawnattr_setsigdefault(&attributes, &defaults)
        guard status == 0 else { return status }

        var flags: Int16 = 0
        status = posix_spawnattr_getflags(&attributes, &flags)
        guard status == 0 else { return status }
        return posix_spawnattr_setflags(
            &attributes,
            flags | Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        )
    }
}
