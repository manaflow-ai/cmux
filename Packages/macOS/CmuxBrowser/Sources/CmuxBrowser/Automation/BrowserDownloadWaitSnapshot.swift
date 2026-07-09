public import Foundation

/// The resolved app-side context for one `browser.download.wait` command, handed
/// from the host (``BrowserControlHosting/resolveBrowserDownloadWaitSnapshot(params:)``)
/// to the package-side worker
/// (``BrowserAutomationController/downloadWaitOnSocketWorker(params:host:)``).
///
/// The workspace/surface resolution, the handle-ref minting, and the queued
/// download-event pop all reach live `TabManager` / `Workspace` / per-surface state
/// on the main actor, so they stay app-side behind the seam; this value is the
/// `Sendable`-shaped (in practice: untyped) snapshot the worker reads. It is the
/// package-side spelling of the former nested
/// `TerminalController.V2BrowserDownloadWaitSnapshot`.
///
/// Intentionally **not** `Sendable`: ``workspaceRef`` / ``surfaceRef`` are the same
/// untyped `Any` handle-ref values the legacy `[String: Any]` payloads carried, the
/// `queuedEvent` is a non-`Sendable` Foundation dictionary, and ``error`` wraps a
/// ``BrowserCommandResult``. The value is built and consumed synchronously on the
/// worker thread (the host resolves it inside its own main hop), never crossing an
/// async boundary.
public struct BrowserDownloadWaitSnapshot {
    /// The resolved owning workspace id (a fresh placeholder when resolution
    /// failed before a workspace was found).
    public let workspaceId: UUID

    /// The `workspace_ref` handle (a `String` ref, or `NSNull()` before a
    /// workspace was resolved).
    public let workspaceRef: Any

    /// The resolved browser surface id (a fresh placeholder when none resolved).
    public let surfaceId: UUID

    /// The `surface_ref` handle (a `String` ref, or `NSNull()` before a surface
    /// was resolved).
    public let surfaceRef: Any

    /// The already-queued download event for the surface, popped on the main
    /// actor; `nil` when a `path` was requested (the file-watch path is used
    /// instead) or when no event was queued.
    public let queuedEvent: [String: Any]?

    /// The terminal failure result when resolution failed; `nil` on success.
    public let error: BrowserCommandResult?

    /// Creates a download-wait context snapshot.
    public init(
        workspaceId: UUID,
        workspaceRef: Any,
        surfaceId: UUID,
        surfaceRef: Any,
        queuedEvent: [String: Any]?,
        error: BrowserCommandResult?
    ) {
        self.workspaceId = workspaceId
        self.workspaceRef = workspaceRef
        self.surfaceId = surfaceId
        self.surfaceRef = surfaceRef
        self.queuedEvent = queuedEvent
        self.error = error
    }
}
