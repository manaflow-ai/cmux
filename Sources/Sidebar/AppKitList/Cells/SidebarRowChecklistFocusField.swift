import AppKit
import CmuxWorkspaces
import SwiftUI

/// The checklist add/edit field: `FocusGrabbingTextField` that also clears
/// the field editor's background AFTER the focus grab. The immediate clear
/// at creation only covers cells configured while already in a window —
/// `tableView(_:viewFor:row:)` configures BEFORE window attachment, and the
/// editor created by the deferred focus grab would otherwise restore the
/// oversized dark editor box.
@MainActor
final class SidebarRowChecklistFocusField: FocusGrabbingTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        SidebarRowChecklistFieldBridge.clearFieldEditorBackground(self)
    }
}
