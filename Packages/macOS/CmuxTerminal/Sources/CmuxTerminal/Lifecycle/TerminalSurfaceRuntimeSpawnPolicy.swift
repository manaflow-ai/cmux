/// How a terminal surface should enter its native Ghostty runtime.
public struct TerminalSurfaceRuntimeSpawnPolicy: Equatable, Sendable {
    let spawnTiming: TerminalSurfaceRuntimeSpawnTiming
    let requiresStartupRestoreAdmission: Bool

    /// Creates the native runtime surface as soon as its view is ready.
    public static let immediate = Self(
        spawnTiming: .immediate,
        requiresStartupRestoreAdmission: false
    )

    /// Paces creation through the restore queue to avoid a login-shell stampede.
    public static let pacedSessionRestore = Self(
        spawnTiming: .pacedSessionRestore,
        requiresStartupRestoreAdmission: false
    )

    /// Holds otherwise-immediate creation until the restore owner admits it.
    public static let heldForStartupRestoreAdmission = Self(
        spawnTiming: .immediate,
        requiresStartupRestoreAdmission: true
    )

    /// Adds explicit restore admission without discarding the current timing.
    ///
    /// This lets relaunch restoration remain paced after its topology owner
    /// releases the runtime, while one-off Vault restores can remain immediate.
    ///
    /// - Returns: A policy with the same spawn timing and an admission gate.
    public func requiringStartupRestoreAdmission() -> Self {
        Self(
            spawnTiming: spawnTiming,
            requiresStartupRestoreAdmission: true
        )
    }
}
