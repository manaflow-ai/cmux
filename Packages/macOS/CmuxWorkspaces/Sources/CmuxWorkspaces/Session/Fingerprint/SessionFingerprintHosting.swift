public import Foundation

/// The window-side seam that flattens the live per-window god state into the
/// `Sendable` ``SessionWorkspaceFingerprintInput`` the ``SessionFingerprintService``
/// hashes.
///
/// **Why a synchronous read-only protocol.** Building the autosave fingerprint
/// input reads ~25 live `Workspace`/`TabManager` fields plus the app's
/// notification store and the per-call restorable-agent / surface-resume-binding
/// indexes, all inside one `@MainActor` turn (the autosave tick). Those reads
/// are irreducibly app-target: the notification store, `TerminalPanel`,
/// `RestorableAgentSessionIndex`, and `SurfaceResumeBindingIndex` are all owned
/// by the executable target, so the conformer (the per-window `TabManager`)
/// stays app-side and the package never imports those types. The conformer
/// flattens everything into value types here; the service then folds the value
/// input into a `Hasher` with no further god reach. This mirrors the
/// ``WorkspaceSessionRestoreHosting`` seam: one synchronous `@MainActor`
/// conformer, package owns the pure logic, app owns the live-state read.
///
/// The two index parameters are opaque to the package (they vary per autosave
/// call), so the host accepts them as already-flattened closures that resolve a
/// panel's restorable-agent and surface-resume-binding snapshots. The host
/// applies them while walking its live tabs.
@MainActor
public protocol SessionFingerprintHosting: AnyObject {
    /// Flattens the current live window state into the fingerprint input.
    ///
    /// - Parameters:
    ///   - resolveRestorableAgent: resolves the flattened restorable-agent
    ///     snapshot for a `(workspaceId, panelId)` pair, reproducing the legacy
    ///     `restorableAgentIndex.snapshot(workspaceId:panelId:)` read.
    ///   - resolveSurfaceResumeBinding: resolves the flattened surface-resume
    ///     binding for a `(workspaceId, panelId)` pair, reproducing the legacy
    ///     `workspace.effectiveSurfaceResumeBinding(panelId:surfaceResumeBindingIndex:)`
    ///     read.
    /// - Returns: the value-typed input the service hashes.
    func makeSessionWorkspaceFingerprintInput(
        resolveRestorableAgent: (_ workspaceId: UUID, _ panelId: UUID)
            -> SessionFingerprintRestorableAgentSnapshot?,
        resolveSurfaceResumeBinding: (_ workspaceId: UUID, _ panelId: UUID)
            -> SessionFingerprintSurfaceResumeBindingSnapshot?
    ) -> SessionWorkspaceFingerprintInput
}
