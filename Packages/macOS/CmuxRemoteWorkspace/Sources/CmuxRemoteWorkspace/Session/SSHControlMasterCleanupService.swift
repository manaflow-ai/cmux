import Foundation

/// Spawns the one-shot `ssh -O exit` process that tears down a lingering SSH
/// ControlMaster multiplexing socket after a remote workspace's last terminal
/// session ends (or its surface is closed/transferred).
///
/// This is the side-effecting half of the legacy
/// `Workspace.requestSSHControlMasterCleanupIfNeeded(configuration:)`: the pure
/// argv computation lives in `CmuxRemoteSession`'s ``RemoteControlMasterCleanup``
/// (a higher package), so the app forwarder computes the argument vector there
/// and hands the resolved `arguments` plus the configuration's
/// `sshProcessEnvironment` to this service to run. Splitting it this way keeps
/// the package dependency graph acyclic (this lower package never reaches up to
/// `CmuxRemoteSession`) while still relocating the spawn off the god object.
///
/// Isolation: the spawn is deliberately fire-and-forget and synchronous from
/// the caller's perspective, matching the legacy static helper (callers on
/// `@MainActor` invoke it without awaiting and the cleanup runs to completion on
/// a background queue). The value type is therefore non-isolated and the actual
/// process work is dispatched onto a process-wide serial queue rather than an
/// actor: an actor hop would force every caller into a `Task` and change the
/// observable timing of teardown. The serial ``cleanupQueue`` is intentionally
/// process-wide (one cleanup spawn at a time across every workspace and window),
/// exactly as the legacy static queue was; making it per-instance would allow
/// concurrent cleanup spawns, a behavior change.
public struct SSHControlMasterCleanupService: Sendable {
    /// Test seam: assign before triggering a cleanup to intercept the resolved
    /// argv instead of spawning `ssh`. Process-wide static to preserve the
    /// legacy `Workspace.runSSHControlMasterCommandOverrideForTesting` contract
    /// (set on the type, read synchronously on the spawn path, reset in a test
    /// `defer`). `nonisolated(unsafe)` because the override is read and written
    /// on the same thread that triggers cleanup and carries no cross-actor
    /// value; the legacy property had the identical annotation.
    nonisolated(unsafe) public static var runCommandOverrideForTesting: (([String]) -> Void)?

    /// Serial queue that owns the cleanup `Process` lifecycle. Process-wide and
    /// `.utility` QoS, byte-faithful to the legacy
    /// `Workspace.sshControlMasterCleanupQueue`.
    private static let cleanupQueue = DispatchQueue(
        label: "com.cmux.remote-ssh.control-master-cleanup",
        qos: .utility
    )

    /// Creates a cleanup spawner.
    public init() {}

    /// Runs `ssh` with `arguments` and `environment` to close the ControlMaster,
    /// or invokes the test override with `arguments` when one is installed.
    ///
    /// Fire-and-forget: returns immediately while the process runs on the
    /// shared serial queue. A 5-second wait bounds the teardown, after which a
    /// still-running process is terminated and given a 1-second grace wait.
    public func requestCleanup(arguments: [String], environment: [String: String]?) {
        if let override = Self.runCommandOverrideForTesting {
            override(arguments)
            return
        }

        Self.cleanupQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let exitSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                exitSemaphore.signal()
            }

            do {
                try process.run()
                if exitSemaphore.wait(timeout: .now() + 5) == .timedOut {
                    if process.isRunning {
                        process.terminate()
                    }
                    _ = exitSemaphore.wait(timeout: .now() + 1)
                }
            } catch {
                return
            }
        }
    }
}
