import AppKit
import SwiftUI

extension GhosttyTerminalView {
    /// A terminal fills its proposal and must not expose the portal-hosted
    /// AppKit view's content-derived fitting size to SwiftUI ancestors.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSView,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? max(1, nsView.bounds.width),
            height: proposal.height ?? max(1, nsView.bounds.height)
        )
    }
}
