import AppKit
import CmuxNextCompat
import CmuxNextDesign
import SwiftUI

/// The mounted custom sidebar (`cmux.sidebar/1`): the script's scene in a scroll view, in place of
/// the workspace list. Ready once its first scene arrives; while it loads or after it fails the
/// sidebar keeps the native list, so a broken script never leaves the user without navigation.
@MainActor
final class AppCustomSidebarContent: SidebarCustomContent {
    private let mount: AppMount
    private weak var client: AppsClient?
    let view: NSView
    var onChange: (() -> Void)?
    private var watch: Task<Void, Never>?

    init(mount: AppMount, client: AppsClient) {
        self.mount = mount
        self.client = client
        view = AppCustomSidebarHostingView(model: mount.model, bundleDirectory: mount.bundleDirectory)
        let model = mount.model
        // task-owner: lives while the sidebar is mounted; release() cancels it. Only the status
        // matters to the host; scene content re-renders inside the view, node by node.
        watch = Task { [weak self] in
            for await _ in ObservationStream({ model.status }) {
                self?.onChange?()
            }
        }
    }

    var isReady: Bool { mount.model.status == .ready }

    var errorText: String? {
        switch mount.model.status {
        case .failed(let reason), .disconnected(let reason): reason
        case .loading, .ready: nil
        }
    }

    func preferredHeight(width: CGFloat) -> CGFloat { view.fittingSize.height }

    func release() {
        watch?.cancel()
        watch = nil
        client?.unmount(mount)
    }
}
