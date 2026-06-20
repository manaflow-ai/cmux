import CmuxMobileBrowser
import CmuxMobileShell
import SwiftUI

#if os(iOS) && DEBUG
/// DEBUG-only shell wrapper for deterministic UI-test harnesses.
///
/// This mounts the workspace shell directly with an injected preview store,
/// bypassing the production auth, onboarding, and pairing gates that
/// ``CMUXMobileRootView`` owns.
public struct CMUXMobilePreviewShellView: View {
    @State private var store: CMUXMobileShellStore
    @State private var browserStore: BrowserSurfaceStore

    /// Creates a preview shell around a prepared mobile shell store.
    /// - Parameters:
    ///   - store: The connected preview store to render.
    ///   - browserStore: The phone-local browser surface store to inject.
    public init(
        store: CMUXMobileShellStore = .preview(),
        browserStore: BrowserSurfaceStore = BrowserSurfaceStore()
    ) {
        _store = State(initialValue: store)
        _browserStore = State(initialValue: browserStore)
    }

    /// The directly-mounted workspace shell for DEBUG preview modes.
    public var body: some View {
        WorkspaceShellView(store: store, signOut: {})
            .environment(browserStore)
    }
}
#endif
