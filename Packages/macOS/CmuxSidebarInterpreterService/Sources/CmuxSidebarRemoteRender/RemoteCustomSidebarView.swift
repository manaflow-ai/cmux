import CmuxSidebarInterpreterClient
import CmuxSwiftRender
import CmuxSwiftRenderUI
import SwiftUI

/// Renders a custom sidebar **fully out-of-process**: interpretation and
/// rendering both happen in the supervised render worker, and this view only
/// hosts the worker's remote layer and forwards input.
///
/// Drop-in counterpart of `CustomSidebarView` (the in-process fallback): same
/// inputs, same look (the worker mounts the shared `CustomSidebarContentView`
/// presentation), but no code or data derived from the user's sidebar file is
/// ever turned into views in the host process.
///
/// Do **not** key the view by file URL: the worker swaps files in place on the
/// next scene message, so the surface (and its hosted remote layer) should stay
/// mounted across sidebar switches to avoid flashing the previous content.
///
/// ```swift
/// RemoteCustomSidebarView(
///     fileURL: url,
///     dataContext: context,
///     dispatch: dispatch,
///     contentInsets: insets,
///     client: renderWorkerClient
/// )
/// ```
public struct RemoteCustomSidebarView: View {
    private let fileURL: URL
    private let dataContext: [String: SwiftValue]
    private let dispatch: SidebarActionDispatch
    private let contentInsets: CustomSidebarContentInsets
    private let client: RenderWorkerClient

    /// Creates a remote sidebar surface bound to a file, a live data context,
    /// an action dispatch, and a supervised render-worker client.
    ///
    /// - Parameters:
    ///   - fileURL: The `.swift` or `.json` sidebar file the worker renders
    ///     and watches.
    ///   - dataContext: Live, read-only values the worker's interpreter binds.
    ///   - dispatch: Runs button/tap actions against the host command surface.
    ///   - contentInsets: Top/bottom scroll insets for the host chrome.
    ///   - client: The render-worker supervisor (one per sidebar host; the
    ///     worker is spawned lazily and survives provider switches).
    public init(
        fileURL: URL,
        dataContext: [String: SwiftValue],
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets = .zero,
        client: RenderWorkerClient
    ) {
        self.fileURL = fileURL
        self.dataContext = dataContext
        self.dispatch = dispatch
        self.contentInsets = contentInsets
        self.client = client
    }

    public var body: some View {
        RemoteSidebarSurface(
            fileURL: fileURL,
            dataContext: dataContext,
            dispatch: dispatch,
            contentInsets: contentInsets,
            client: client
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Bridges the AppKit surface view into SwiftUI and pushes scene updates on
/// every relevant SwiftUI update.
private struct RemoteSidebarSurface: NSViewRepresentable {
    let fileURL: URL
    let dataContext: [String: SwiftValue]
    let dispatch: SidebarActionDispatch
    let contentInsets: CustomSidebarContentInsets
    let client: RenderWorkerClient

    func makeNSView(context: Context) -> RemoteSidebarSurfaceView {
        let view = RemoteSidebarSurfaceView(client: client)
        view.dispatch = dispatch
        view.pushScene(filePath: fileURL.path, state: dataContext, insets: contentInsets)
        return view
    }

    func updateNSView(_ view: RemoteSidebarSurfaceView, context: Context) {
        view.dispatch = dispatch
        view.pushScene(filePath: fileURL.path, state: dataContext, insets: contentInsets)
    }

    static func dismantleNSView(_ view: RemoteSidebarSurfaceView, coordinator: ()) {
        view.teardown()
    }
}
