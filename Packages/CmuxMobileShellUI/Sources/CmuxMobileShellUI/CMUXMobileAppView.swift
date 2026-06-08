import CmuxMobileBrowser
import CmuxMobileShell
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct CMUXMobileAppView: View {
    @State private var store: CMUXMobileShellStore
    /// Phone-local browser surfaces, owned for the app's lifetime and injected
    /// into the environment so the workspace detail view can present a browser
    /// pane without threading the store through every intermediate view. Browser
    /// state lives here (not in the shell store) because, unlike terminals, it
    /// has no Mac-side counterpart and must survive `workspace.updated` re-syncs.
    @State private var browserStore: BrowserSurfaceStore

    public init(
        store: CMUXMobileShellStore = .preview(),
        browserStore: BrowserSurfaceStore = BrowserSurfaceStore()
    ) {
        _store = State(initialValue: store)
        _browserStore = State(initialValue: browserStore)
    }

    public var body: some View {
        CMUXMobileRootView(store: store)
            .environment(browserStore)
    }
}
