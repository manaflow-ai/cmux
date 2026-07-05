public import CmuxMobileRPC

/// Factory for in-memory ``MobileShellComposite`` preview and test stores.
public struct MobileShellCompositePreviewFactory {
    /// Creates a shell store backed by static preview fixtures.
    ///
    /// - Parameter runtime: Optional runtime seam used by tests that need
    ///   deterministic clocks, timeouts, or clients.
    /// - Returns: A store seeded with the preview host workspace list.
    @MainActor public func callAsFunction(runtime: (any MobileSyncRuntime)? = nil) -> CMUXMobileShellStore {
        CMUXMobileShellStore(
            runtime: runtime,
            workspaces: PreviewMobileHost.workspaces,
            deliveredNotificationClearer: NoopDeliveredNotificationClearer()
        )
    }
}
