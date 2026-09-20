import Foundation

/// Terminal-free routing owner used before a main window is registered.
extension TabManager {
    /// Creates the process-level command-routing fallback used before AppKit
    /// registers a real per-window manager.
    ///
    /// This bootstrap owner must remain terminal-free because SwiftUI may
    /// initialize the app value more than once during launch.
    static func makeAppBootstrap(
        workspaceCustomizationStore: WorkspaceCustomizationStore? = nil,
        nativeSSHConnectionBroker: NativeSSHConnectionBroker = NativeSSHConnectionBroker()
    ) -> TabManager {
        TabManager(
            createInitialWorkspace: false,
            workspaceCustomizationStore: workspaceCustomizationStore,
            nativeSSHConnectionBroker: nativeSSHConnectionBroker
        )
    }
}
