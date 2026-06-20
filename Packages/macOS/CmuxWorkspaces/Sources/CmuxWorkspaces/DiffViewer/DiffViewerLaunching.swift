public import Foundation

/// Capability to open the cmux diff viewer for a workspace by spawning the
/// bundled `cmux diff` CLI as a detached child process.
///
/// The command-palette entry and the Open Diff Viewer keyboard shortcut both
/// funnel through the single app-target orchestration method, which resolves
/// the focused workspace and the bundled CLI, then delegates the actual
/// process launch to this seam. Consumers depend on ``DiffViewerLaunching``
/// instead of the concrete ``DiffViewerLaunchService`` so the launch can be
/// tested with a recording fake and the process-lifecycle registry never
/// lives on the app delegate.
public protocol DiffViewerLaunching: Sendable {
    /// Spawns `cmux diff --unstaged` for the given workspace.
    ///
    /// - Parameters:
    ///   - cliURL: Absolute URL of the bundled `cmux` executable.
    ///   - socketPath: Control socket the spawned CLI connects back through.
    ///   - cwd: Working directory passed as `--cwd` and used as the process's
    ///     current directory.
    ///   - workspaceId: Workspace the diff viewer targets (`--workspace`).
    ///   - surfaceId: Optional focused surface (`--surface`) the viewer opens
    ///     beside.
    /// - Returns: `true` when the process launched; `false` when `Process.run`
    ///   threw, in which case the caller beeps.
    @MainActor
    @discardableResult
    func launch(
        cliURL: URL,
        socketPath: String,
        cwd: String,
        workspaceId: UUID,
        surfaceId: UUID?
    ) -> Bool
}
