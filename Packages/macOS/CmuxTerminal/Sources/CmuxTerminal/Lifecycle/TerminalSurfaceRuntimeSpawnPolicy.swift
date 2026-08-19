/// How a terminal surface should enter its native Ghostty runtime.
public struct TerminalSurfaceRuntimeSpawnPolicy: Equatable, Sendable {
    let spawnTiming: TerminalSurfaceRuntimeSpawnTiming
    let requiresStartupRestoreAdmission: Bool
    /// Whether the declarative cmux shell-startup defaults may affect this
    /// surface. Restore transactions opt out even when their runtime is
    /// admitted immediately, so a restored shell is never given a new
    /// startup command or login-mode override.
    public let allowsDeclarativeStartupDefaults: Bool
    /// Whether the declarative cmux working-directory defaults may affect this
    /// surface. This is intentionally independent from
    /// ``allowsDeclarativeStartupDefaults``: an explicit local command still
    /// needs the configured cwd, while its shell startup mode is suppressed.
    public let allowsDeclarativeWorkingDirectoryDefaults: Bool

    /// Creates the native runtime surface as soon as its view is ready.
    public static let immediate = Self(
        spawnTiming: .immediate,
        requiresStartupRestoreAdmission: false,
        allowsDeclarativeStartupDefaults: true,
        allowsDeclarativeWorkingDirectoryDefaults: true
    )

    /// Paces creation through the restore queue to avoid a login-shell stampede.
    public static let pacedSessionRestore = Self(
        spawnTiming: .pacedSessionRestore,
        requiresStartupRestoreAdmission: false,
        allowsDeclarativeStartupDefaults: false,
        allowsDeclarativeWorkingDirectoryDefaults: false
    )

    /// Holds otherwise-immediate creation until the restore owner admits it.
    public static let heldForStartupRestoreAdmission = Self(
        spawnTiming: .immediate,
        requiresStartupRestoreAdmission: true,
        allowsDeclarativeStartupDefaults: false,
        allowsDeclarativeWorkingDirectoryDefaults: false
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
            requiresStartupRestoreAdmission: true,
            allowsDeclarativeStartupDefaults: allowsDeclarativeStartupDefaults,
            allowsDeclarativeWorkingDirectoryDefaults: allowsDeclarativeWorkingDirectoryDefaults
        )
    }

    /// Marks an otherwise immediate surface as a restored transaction.
    ///
    /// - Returns: A policy that preserves timing and admission while opting
    ///   out of declarative defaults.
    public func forRestoredSurface() -> Self {
        withoutDeclarativeDefaults()
    }

    /// Marks a surface as explicit so declarative shell-startup defaults
    /// cannot rewrite its launch while cwd defaults remain eligible.
    ///
    /// - Returns: A policy that preserves timing and admission while opting
    ///   out of shell-startup defaults.
    public func withoutDeclarativeStartupDefaults() -> Self {
        Self(
            spawnTiming: spawnTiming,
            requiresStartupRestoreAdmission: requiresStartupRestoreAdmission,
            allowsDeclarativeStartupDefaults: false,
            allowsDeclarativeWorkingDirectoryDefaults: allowsDeclarativeWorkingDirectoryDefaults
        )
    }

    /// Marks a surface whose cwd is owned by a restore, remote, or layout
    /// transaction while preserving the shell-default decision.
    ///
    /// - Returns: A policy with only working-directory defaults disabled.
    public func withoutDeclarativeWorkingDirectoryDefaults() -> Self {
        Self(
            spawnTiming: spawnTiming,
            requiresStartupRestoreAdmission: requiresStartupRestoreAdmission,
            allowsDeclarativeStartupDefaults: allowsDeclarativeStartupDefaults,
            allowsDeclarativeWorkingDirectoryDefaults: false
        )
    }

    /// Marks a surface as fully externally managed by a restore, remote, or
    /// declarative-layout transaction.
    ///
    /// - Returns: A policy with both declarative default families disabled.
    public func withoutDeclarativeDefaults() -> Self {
        Self(
            spawnTiming: spawnTiming,
            requiresStartupRestoreAdmission: requiresStartupRestoreAdmission,
            allowsDeclarativeStartupDefaults: false,
            allowsDeclarativeWorkingDirectoryDefaults: false
        )
    }

    /// Resolves declarative-default eligibility for a surface-creation intent.
    ///
    /// Restore transactions suppress both families. Otherwise explicit startup
    /// work suppresses only shell defaults, while an externally managed cwd
    /// suppresses only working-directory defaults. Keeping this decision on the
    /// policy prevents individual creation entrypoints from drifting.
    ///
    /// - Parameters:
    ///   - isRestoredSurface: Whether the surface recreates persisted state.
    ///   - hasExplicitStartupWork: Whether a command or input already owns shell startup.
    ///   - hasExternallyManagedWorkingDirectory: Whether restore, remote, tmux,
    ///     or declarative-layout state owns the cwd.
    /// - Returns: A policy with declarative defaults enabled only where safe.
    public func resolvingDeclarativeDefaults(
        isRestoredSurface: Bool,
        hasExplicitStartupWork: Bool,
        hasExternallyManagedWorkingDirectory: Bool
    ) -> Self {
        if isRestoredSurface {
            return withoutDeclarativeDefaults()
        }

        var resolved = self
        if hasExplicitStartupWork {
            resolved = resolved.withoutDeclarativeStartupDefaults()
        }
        if hasExternallyManagedWorkingDirectory {
            resolved = resolved.withoutDeclarativeWorkingDirectoryDefaults()
        }
        return resolved
    }
}
