public import CMUXMobileCore
public import CmuxMobileShellModel

/// Builds preview and test shell stores with explicit preview-only dependencies.
public struct MobileShellPreviewFactory {
    private let runtime: (any MobileSyncRuntime)?
    private let manualHostTrustStore: any MobileManualHostTrustStoring

    /// Creates a preview shell factory.
    /// - Parameters:
    ///   - runtime: Optional runtime used by previews or package tests.
    ///   - manualHostTrustStore: Store used to persist manual-host approvals in the preview shell.
    public init(
        runtime: (any MobileSyncRuntime)? = nil,
        manualHostTrustStore: any MobileManualHostTrustStoring = InMemoryMobileManualHostTrustStore()
    ) {
        self.runtime = runtime
        self.manualHostTrustStore = manualHostTrustStore
    }

    /// Creates a shell store seeded with preview workspaces.
    /// - Returns: A shell store configured for previews or package tests.
    @MainActor
    public func makeStore() -> CMUXMobileShellStore {
        CMUXMobileShellStore(
            runtime: runtime,
            workspaces: PreviewMobileHost.workspaces,
            deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
            manualHostTrustStore: manualHostTrustStore
        )
    }
}
