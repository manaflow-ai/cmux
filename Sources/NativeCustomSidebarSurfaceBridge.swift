import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import SwiftUI

/// Transitional mount for the native custom-sidebar surface while the parent
/// window is still being moved to its AppKit controller.
struct NativeCustomSidebarSurfaceBridge: NSViewRepresentable {
    let fileURL: URL
    let dataContext: [String: SwiftValue]
    let dispatch: SidebarActionDispatch
    let contentInsets: CustomSidebarContentInsets
    let rendersInProcess: Bool
    let clientStore: RenderWorkerClientStore

    func makeNSView(context: Context) -> CustomSidebarSurface {
        CustomSidebarSurface(
            fileURL: fileURL,
            dataContext: dataContext,
            dispatch: dispatch,
            contentInsets: contentInsets,
            rendersInProcess: rendersInProcess,
            clientStore: clientStore
        )
    }

    func updateNSView(_ view: CustomSidebarSurface, context: Context) {
        view.update(
            fileURL: fileURL,
            dataContext: dataContext,
            dispatch: dispatch,
            contentInsets: contentInsets,
            rendersInProcess: rendersInProcess
        )
    }

    static func dismantleNSView(_ view: CustomSidebarSurface, coordinator: ()) {
        view.teardown()
    }
}
