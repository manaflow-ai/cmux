import AppKit
import CmuxSidebarInterpreterClient
import CmuxSwiftRender
import CmuxSwiftRenderUI

/// Native mount seam for a selected custom sidebar.
///
/// The surface switches between in-process rendering and a crash-isolated
/// remote layer while keeping a window-owned worker client warm.
@MainActor
public final class CustomSidebarSurface: NSView {
    public let clientStore: RenderWorkerClientStore

    private var mountedView: NSView?
    private var mountedFilePath: String?
    private var rendersInProcess = true

    /// Creates the surface and mounts the selected render lane.
    public init(
        fileURL: URL,
        dataContext: [String: SwiftValue],
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets = .zero,
        rendersInProcess: Bool = true,
        clientStore: RenderWorkerClientStore = RenderWorkerClientStore()
    ) {
        self.clientStore = clientStore
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)
        update(
            fileURL: fileURL,
            dataContext: dataContext,
            dispatch: dispatch,
            contentInsets: contentInsets,
            rendersInProcess: rendersInProcess
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Applies host state, rebuilding only when the renderer or source changes.
    public func update(
        fileURL: URL,
        dataContext: [String: SwiftValue],
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets,
        rendersInProcess: Bool
    ) {
        let filePath = fileURL.standardizedFileURL.path
        let sourceChanged = mountedFilePath != filePath
        let laneChanged = self.rendersInProcess != rendersInProcess
        self.rendersInProcess = rendersInProcess

        if rendersInProcess {
            if !sourceChanged, !laneChanged, let view = mountedView as? CustomSidebarView {
                view.update(dataContext: dataContext, contentInsets: contentInsets)
                return
            }
            let view = CustomSidebarView(
                fileURL: fileURL,
                dataContext: dataContext,
                dispatch: dispatch,
                contentInsets: contentInsets
            )
            replaceMountedView(with: view, filePath: filePath)
        } else {
            if !laneChanged, let view = mountedView as? RemoteCustomSidebarHost {
                view.update(
                    fileURL: fileURL,
                    dataContext: dataContext,
                    dispatch: dispatch,
                    contentInsets: contentInsets
                )
                mountedFilePath = filePath
                return
            }
            let view = RemoteCustomSidebarHost(
                fileURL: fileURL,
                dataContext: dataContext,
                dispatch: dispatch,
                contentInsets: contentInsets,
                clientStore: clientStore
            )
            replaceMountedView(with: view, filePath: filePath)
        }
    }

    /// Stops view-owned observation and message streams without stopping the
    /// window-owned worker client.
    public func teardown() {
        (mountedView as? CustomSidebarView)?.stop()
        (mountedView as? RemoteCustomSidebarHost)?.teardown()
        mountedView?.removeFromSuperview()
        mountedView = nil
        mountedFilePath = nil
    }

    private func replaceMountedView(with view: NSView, filePath: String) {
        (mountedView as? CustomSidebarView)?.stop()
        (mountedView as? RemoteCustomSidebarHost)?.teardown()
        mountedView?.removeFromSuperview()
        mountedView = view
        mountedFilePath = filePath
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
