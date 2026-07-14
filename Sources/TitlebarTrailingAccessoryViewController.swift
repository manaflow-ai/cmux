import AppKit
import SwiftUI

/// Hosts the per-window controls anchored to the trailing edge of the title bar.
final class TitlebarTrailingAccessoryViewController: NSTitlebarAccessoryViewController {
    let fileExplorerState: FileExplorerState

    init(fileExplorerState: FileExplorerState, onToggleRightSidebar: @escaping () -> Void) {
        self.fileExplorerState = fileExplorerState
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .right

        let hosting = NSHostingView(
            rootView: TitlebarTrailingControls(
                fileExplorerState: fileExplorerState,
                onToggleRightSidebar: onToggleRightSidebar
            )
        )
        hosting.setContentHuggingPriority(.required, for: .horizontal)
        hosting.wantsLayer = true
        hosting.clipsToBounds = false
        hosting.layer?.masksToBounds = false
        view = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
