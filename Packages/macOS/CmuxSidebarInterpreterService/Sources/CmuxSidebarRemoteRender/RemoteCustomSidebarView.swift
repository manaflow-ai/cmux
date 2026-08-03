import AppKit
import CmuxSidebarInterpreterClient
import CmuxSwiftRender
import CmuxSwiftRenderUI

/// Native host-process surface for a fully isolated custom-sidebar renderer.
@MainActor
public final class RemoteCustomSidebarView: NSView {
    let client: RenderWorkerClient
    private let surfaceView: RemoteSidebarSurfaceView

    /// Creates a remote surface bound to a supervised worker client.
    public init(
        fileURL: URL,
        dataContext: [String: SwiftValue],
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets = .zero,
        client: RenderWorkerClient
    ) {
        self.client = client
        surfaceView = RemoteSidebarSurfaceView(client: client)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surfaceView)
        NSLayoutConstraint.activate([
            surfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
            surfaceView.topAnchor.constraint(equalTo: topAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        update(
            fileURL: fileURL,
            dataContext: dataContext,
            dispatch: dispatch,
            contentInsets: contentInsets
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Pushes a changed source, data snapshot, or host inset to the worker.
    public func update(
        fileURL: URL,
        dataContext: [String: SwiftValue],
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets
    ) {
        surfaceView.dispatch = dispatch
        surfaceView.pushScene(
            filePath: fileURL.path,
            state: dataContext,
            insets: contentInsets
        )
    }

    /// Stops host-side streams. The owning store decides worker lifetime.
    public func teardown() {
        surfaceView.teardown()
    }
}
