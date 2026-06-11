import CmuxSidebarInterpreterClient
import CmuxSwiftRender
import CmuxSwiftRenderUI
import SwiftUI

/// Mounts a custom sidebar against a window-owned render-worker client.
///
/// The client is owned by the window's root view and passed in as a binding,
/// not held here: this branch unmounts whenever the sidebar hides or the
/// provider switches, and client-per-mount meant every reopen paid a worker
/// spawn + first render (~1s of blank). With window ownership the worker
/// stays warm across toggles and a remount adopts the cached remote context
/// synchronously. The client is still created lazily on the first mount
/// (never eagerly in the window view: the re-land bisect implicated eager
/// per-init allocation in host-wide test interference), is shut down by the
/// surface's window-close reaper, and the worker also exits on pipe EOF if
/// the owning window deallocates while the sidebar is hidden.
public struct RemoteCustomSidebarHost: View {
    private let fileURL: URL
    private let dataContext: [String: SwiftValue]
    private let dispatch: SidebarActionDispatch
    private let contentInsets: CustomSidebarContentInsets

    @Binding private var client: RenderWorkerClient?
    private var sourceKey: String { fileURL.standardizedFileURL.path }

    /// Creates the host.
    ///
    /// - Parameters:
    ///   - fileURL: The `.swift` or `.json` sidebar file the worker renders
    ///     and watches.
    ///   - dataContext: Live, read-only values the worker's interpreter binds.
    ///   - dispatch: Runs button/tap actions against the host command surface.
    ///   - contentInsets: Top/bottom scroll insets for the host chrome.
    ///   - client: Window-owned worker client storage; created lazily on the
    ///     first mount and reused across sidebar toggles and provider
    ///     switches within that window.
    public init(
        fileURL: URL,
        dataContext: [String: SwiftValue],
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets = .zero,
        client: Binding<RenderWorkerClient?>
    ) {
        self.fileURL = fileURL
        self.dataContext = dataContext
        self.dispatch = dispatch
        self.contentInsets = contentInsets
        self._client = client
    }

    public var body: some View {
        Group {
            if let client, client.sourceKey == sourceKey {
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
        .task(id: sourceKey) {
            guard client?.sourceKey != sourceKey else { return }
            let previous = client
            client = RenderWorkerClient.reexecingCurrentBinary(sourceKey: sourceKey)
            if let previous {
                await previous.shutdown()
            }
        }
    }
}
