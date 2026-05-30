import Foundation

/// Typed command channel from a sidebar extension back to CMUX.
@MainActor
public struct CmuxSidebarHost {
    private let performAction: @MainActor @Sendable (CMUXSidebarAction, @escaping @MainActor @Sendable (CMUXExtensionActionResult) -> Void) -> CmuxSidebarActionCancellation?
    private let refreshSnapshot: @MainActor @Sendable () -> Void

    public init(
        performAction: @escaping @MainActor @Sendable (CMUXSidebarAction, @escaping @MainActor @Sendable (CMUXExtensionActionResult) -> Void) -> Void,
        refreshSnapshot: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.performAction = { action, reply in
            performAction(action, reply)
            return nil
        }
        self.refreshSnapshot = refreshSnapshot
    }

    /// Creates a typed host channel with cancellable action dispatch.
    ///
    /// Use this initializer when the underlying transport can remove pending
    /// replies after the caller's task is cancelled.
    public init(
        performCancellableAction: @escaping @MainActor @Sendable (CMUXSidebarAction, @escaping @MainActor @Sendable (CMUXExtensionActionResult) -> Void) -> CmuxSidebarActionCancellation?,
        refreshSnapshot: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.performAction = performCancellableAction
        self.refreshSnapshot = refreshSnapshot
    }

    /// Requests the latest sidebar snapshot from CMUX.
    public func refresh() {
        refreshSnapshot()
    }

    /// Selects a workspace in CMUX.
    public func selectWorkspace(_ id: UUID) async -> CMUXExtensionActionResult {
        await perform(.selectWorkspace(id))
    }

    /// Requests that CMUX close a workspace.
    public func closeWorkspace(_ id: UUID) async -> CMUXExtensionActionResult {
        await perform(.closeWorkspace(id))
    }

    /// Requests that CMUX open a web URL.
    public func openURL(_ url: URL) async -> CMUXExtensionActionResult {
        await perform(.openURL(url.absoluteString))
    }

    /// Requests that CMUX create a terminal surface.
    ///
    /// Extensions can ask CMUX to create the surface, but cannot seed shell
    /// input. This keeps `.createSurface` separate from command execution.
    public func createTerminalSurface(in workspaceID: UUID? = nil) async -> CMUXExtensionActionResult {
        await perform(.createTerminalSurface(workspaceID: workspaceID))
    }

    /// Requests that CMUX create a terminal surface.
    ///
    /// The `initialInput` parameter is ignored. It remains only so early
    /// sidebar extensions can compile while moving to the safer overload.
    @available(*, deprecated, message: "CMUX sidebar extensions cannot seed terminal input. Use createTerminalSurface(in:) instead.")
    public func createTerminalSurface(
        in workspaceID: UUID? = nil,
        initialInput _: String?
    ) async -> CMUXExtensionActionResult {
        await createTerminalSurface(in: workspaceID)
    }

    public func createBrowserSurface(
        in workspaceID: UUID? = nil,
        url: URL? = nil
    ) async -> CMUXExtensionActionResult {
        await perform(.createBrowserSurface(workspaceID: workspaceID, url: url?.absoluteString))
    }

    public func selectSurface(workspaceID: UUID, surfaceID: UUID) async -> CMUXExtensionActionResult {
        await perform(.selectSurface(workspaceID: workspaceID, surfaceID: surfaceID))
    }

    public func selectNextSurface() async -> CMUXExtensionActionResult {
        await perform(.selectNextSurface)
    }

    public func selectPreviousSurface() async -> CMUXExtensionActionResult {
        await perform(.selectPreviousSurface)
    }

    public func closeSurface(workspaceID: UUID, surfaceID: UUID) async -> CMUXExtensionActionResult {
        await perform(.closeSurface(workspaceID: workspaceID, surfaceID: surfaceID))
    }

    public func splitTerminal(
        workspaceID: UUID,
        surfaceID: UUID,
        direction: CMUXSplitDirection
    ) async -> CMUXExtensionActionResult {
        await perform(.splitTerminal(workspaceID: workspaceID, surfaceID: surfaceID, direction: direction))
    }

    public func splitBrowser(
        workspaceID: UUID,
        surfaceID: UUID,
        direction: CMUXSplitDirection,
        url: URL? = nil
    ) async -> CMUXExtensionActionResult {
        await perform(.splitBrowser(workspaceID: workspaceID, surfaceID: surfaceID, direction: direction, url: url?.absoluteString))
    }

    public func toggleSurfaceZoom(workspaceID: UUID, surfaceID: UUID) async -> CMUXExtensionActionResult {
        await perform(.toggleSurfaceZoom(workspaceID: workspaceID, surfaceID: surfaceID))
    }

    /// Sends a raw sidebar action and returns CMUX's acceptance result.
    public func perform(_ action: CMUXSidebarAction) async -> CMUXExtensionActionResult {
        let replyGate = CmuxSidebarActionReplyGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    guard replyGate.setContinuation(continuation) else { return }
                    let cancellation = performAction(action) { result in
                        replyGate.resume(returning: result)
                    }
                    replyGate.setCancellation(cancellation)
                }
            }
        } onCancel: {
            replyGate.cancel()
        }
    }

    /// Sends a raw sidebar action. Prefer the async typed helpers above when possible.
    public func perform(
        _ action: CMUXSidebarAction,
        reply: @escaping @MainActor @Sendable (CMUXExtensionActionResult) -> Void
    ) {
        _ = performAction(action, reply)
    }
}

private final class CmuxSidebarActionReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CMUXExtensionActionResult, Never>?
    private var cancellation: CmuxSidebarActionCancellation?
    private var didComplete = false

    func setContinuation(_ continuation: CheckedContinuation<CMUXExtensionActionResult, Never>) -> Bool {
        lock.lock()
        if didComplete {
            lock.unlock()
            continuation.resume(returning: .rejected("Extension action was cancelled"))
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setCancellation(_ cancellation: CmuxSidebarActionCancellation?) {
        lock.lock()
        if didComplete {
            lock.unlock()
            cancellation?.cancel()
            return
        }
        self.cancellation = cancellation
        lock.unlock()
    }

    func resume(returning result: CMUXExtensionActionResult) {
        let continuation = complete()
        continuation?.resume(returning: result)
    }

    func cancel() {
        let cancellation: CmuxSidebarActionCancellation?
        let continuation: CheckedContinuation<CMUXExtensionActionResult, Never>?
        lock.lock()
        if didComplete {
            lock.unlock()
            return
        }
        didComplete = true
        cancellation = self.cancellation
        continuation = self.continuation
        self.cancellation = nil
        self.continuation = nil
        lock.unlock()

        cancellation?.cancel()
        continuation?.resume(returning: .rejected("Extension action was cancelled"))
    }

    private func complete() -> CheckedContinuation<CMUXExtensionActionResult, Never>? {
        lock.lock()
        if didComplete {
            lock.unlock()
            return nil
        }
        didComplete = true
        let continuation = self.continuation
        self.continuation = nil
        self.cancellation = nil
        lock.unlock()
        return continuation
    }
}
