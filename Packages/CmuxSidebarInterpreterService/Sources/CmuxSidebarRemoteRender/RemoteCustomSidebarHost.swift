import CmuxSidebarInterpreterClient
import CmuxSwiftRender
import CmuxSwiftRenderUI
import SwiftUI

/// Owns the render-worker client for a mounted custom sidebar.
///
/// The client (and therefore the worker process) exists only while a custom
/// sidebar is actually selected: creating it eagerly in the sidebar host
/// meant every sidebar render in every window evaluated the client
/// initializer, and the re-land bisect implicated that wiring in host-wide
/// test interference. The worker still spawns lazily on the first scene and
/// is terminated by the surface's window-close reaper.
public struct RemoteCustomSidebarHost: View {
    private let fileURL: URL
    private let dataContext: [String: SwiftValue]
    private let dispatch: SidebarActionDispatch
    private let contentInsets: CustomSidebarContentInsets

    /// Created once on mount (never in the initializer: this view sits
    /// inside a per-second TimelineView, and a function-call `@State`
    /// default would evaluate — allocating a client — on every re-init).
    @State private var client: RenderWorkerClient?

    /// Creates the host.
    ///
    /// - Parameters:
    ///   - fileURL: The `.swift` or `.json` sidebar file the worker renders
    ///     and watches.
    ///   - dataContext: Live, read-only values the worker's interpreter binds.
    ///   - dispatch: Runs button/tap actions against the host command surface.
    ///   - contentInsets: Top/bottom scroll insets for the host chrome.
    public init(
        fileURL: URL,
        dataContext: [String: SwiftValue],
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets = .zero
    ) {
        self.fileURL = fileURL
        self.dataContext = dataContext
        self.dispatch = dispatch
        self.contentInsets = contentInsets
    }

    public var body: some View {
        Group {
            if let client {
                RemoteCustomSidebarView(
                    fileURL: fileURL,
                    dataContext: dataContext,
                    dispatch: dispatch,
                    contentInsets: contentInsets,
                    client: client
                )
            } else {
                Color.clear
            }
        }
        .task {
            if client == nil {
                client = RenderWorkerClient.reexecingCurrentBinary()
            }
        }
        .onDisappear {
            // The branch unmounted (provider switch or sidebar hidden); the
            // discarded @State client would orphan its worker until window
            // close, so reap it here. Re-entering custom sidebars respawns
            // within a scene tick.
            if let client {
                Task { await client.shutdown() }
            }
        }
    }
}
