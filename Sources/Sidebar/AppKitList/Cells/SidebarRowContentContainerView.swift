import AppKit
import CmuxWorkspaces
import SwiftUI

/// Flipped host for the row's content subviews; its `alphaValue` implements
/// the legacy Done-row dim (content composites as one group at 60%).
@MainActor
final class SidebarRowContentContainerView: NSView {
    override var isFlipped: Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        (superview as? SidebarWorkspaceRowTableCellView)?.menu(for: event)
            ?? super.menu(for: event)
    }
}
