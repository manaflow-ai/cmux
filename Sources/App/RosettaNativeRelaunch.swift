import Darwin
import Foundation
import os

nonisolated private let rosettaRelaunchLogger = Logger(subsystem: "com.cmuxterm.app", category: "RosettaRelaunch")

/// Launch-time self-heal that re-execs cmux natively when the process is
/// running translated under Rosetta on Apple Silicon.
///
/// cmux ships a universal (`x86_64 arm64`) binary so it keeps supporting Intel
/// Macs. On Apple Silicon, a stale LaunchServices architecture preference (set
/// once from the DMG volume copy and inherited by the `/Applications` copy) can
/// pin the app to its `x86_64` slice, so the whole process tree — login shell,
/// `zsh`, and every tool launched in a cmux terminal — runs translated. macOS 26
/// then shows a Rosetta deprecation dialog. `LSArchitecturePriority = (arm64)`
/// in the app `Info.plist` fixes future launches; this type corrects an
/// already-mis-pinned install by re-launching the arm64 slice in place at
/// startup, mirroring ``CLIForwardingLaunchRouter``'s re-exec shape.
enum RosettaNativeRelaunch {
    /// Environment guard that marks a process as the product of a native
    /// relaunch, so a relaunch that fails to escape translation never loops.
    private static let guardKey = "CMUX_ROSETTA_RELAUNCHED"

    /// Whether the current process should re-exec itself as a native arm64
    /// binary.
    ///
    /// Pure decision logic with no side effects so it is unit-testable without
    /// launching the app: relaunch exactly when the process is translated and a
    /// native relaunch has not already been attempted. On Intel hardware and on
    /// natively-launched Apple Silicon processes `isTranslated` is `false`, so
    /// this returns `false` and the app proceeds unchanged.
    ///
    /// - Parameters:
    ///   - isTranslated: Whether the process is running under Rosetta
    ///     translation (`sysctl.proc_translated == 1`).
    ///   - hasAttemptedRelaunch: Whether a native relaunch was already attempted
    ///     in this launch chain (the guard env var is present).
    /// - Returns: `true` when the process should re-exec natively.
    static func shouldRelaunchNatively(isTranslated: Bool, hasAttemptedRelaunch: Bool) -> Bool {
        isTranslated && !hasAttemptedRelaunch
    }

    /// Whether this process is running under Rosetta translation.
    ///
    /// Reads `sysctl.proc_translated`. The key is absent on Intel Macs and on
    /// older systems, which `sysctlbyname` reports as a failure; that case is
    /// treated as "not translated".
    static func isProcessTranslated() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0)
        if result != 0 { return false }
        return value == 1
    }

    /// Re-exec cmux as a native arm64 process when it is running translated.
    ///
    /// Call this as early as possible at launch — before CLI forwarding and
    /// before AppKit is brought up — so a translated launch invoked with
    /// CLI-style arguments is re-execed natively first and the forwarded bundled
    /// CLI inherits the native arch. When ``shouldRelaunchNatively(isTranslated:hasAttemptedRelaunch:)``
    /// is `true`, it replaces the current process image in place with the
    /// arm64 slice of the same bundle executable via `posix_spawn` configured
    /// with `POSIX_SPAWN_SETEXEC` and an arm64 binary preference. The call only
    /// returns when no relaunch was needed or when the relaunch failed; on
    /// failure it logs and lets the (still translated) process continue rather
    /// than crashing.
    ///
    /// - Parameters:
    ///   - isTranslated: Translation state; defaults to a live `sysctl` read.
    ///   - hasAttemptedRelaunch: Loop guard; defaults to the presence of the
    ///     guard env var.
    ///   - executablePath: The Mach-O to re-exec; defaults to the running
    ///     bundle executable.
    ///   - arguments: The argument vector to preserve; defaults to the current
    ///     process arguments.
    static func relaunchNativelyIfNeeded(
        isTranslated: Bool = isProcessTranslated(),
        hasAttemptedRelaunch: Bool = getenv(guardKey) != nil,
        executablePath: String? = Bundle.main.executablePath,
        arguments: [String] = CommandLine.arguments
    ) {
        guard shouldRelaunchNatively(isTranslated: isTranslated, hasAttemptedRelaunch: hasAttemptedRelaunch) else {
            return
        }
        guard let executablePath else {
            rosettaRelaunchLogger.warning("translated launch detected but bundle executable path is unavailable; continuing translated")
            return
        }

        // Mark descendants of the relaunch so a relaunch that fails to escape
        // translation cannot loop.
        setenv(guardKey, "1", 1)

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            rosettaRelaunchLogger.warning("failed to init posix_spawnattr; continuing translated")
            unsetenv(guardKey)
            return
        }
        defer { posix_spawnattr_destroy(&attributes) }

        // Replace the current process image in place (like exec) so there is no
        // orphaned translated process and the PID is preserved. If the flag
        // cannot be set, `posix_spawn` would fork a second process instead of
        // replacing this one, leaving a translated parent running alongside a
        // native child — so bail out rather than spawn without SETEXEC.
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC)) == 0 else {
            rosettaRelaunchLogger.warning("failed to set POSIX_SPAWN_SETEXEC; continuing translated")
            unsetenv(guardKey)
            return
        }

        // Force the arm64 slice of the universal binary so the replacement
        // process is native, not translated. Without an explicit preference the
        // kernel would re-select the x86_64 slice that this translated process
        // is already running.
        var cpuPreference = cpu_type_t(CPU_TYPE_ARM64)
        var selectedCount = 0
        let binprefResult = posix_spawnattr_setbinpref_np(&attributes, 1, &cpuPreference, &selectedCount)
        guard binprefResult == 0, selectedCount == 1 else {
            rosettaRelaunchLogger.warning("failed to set arm64 binary preference; continuing translated")
            unsetenv(guardKey)
            return
        }

        var cArguments = arguments.map { strdup($0) }
        cArguments.append(nil)
        defer { for argument in cArguments where argument != nil { free(argument) } }

        var pid: pid_t = 0
        let spawnResult = executablePath.withCString { path in
            posix_spawn(&pid, path, nil, &attributes, &cArguments, environ)
        }

        // With POSIX_SPAWN_SETEXEC a successful call never returns. Reaching
        // here means the re-exec failed; log and fall through so the app still
        // launches (translated) instead of dying. Only the errno is logged (not
        // the executable path) to keep user-specific install paths out of the
        // unified log.
        rosettaRelaunchLogger.warning("native re-exec failed (errno \(spawnResult, privacy: .public)); continuing translated")
        unsetenv(guardKey)
    }
}
