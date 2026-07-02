#if os(iOS)
import CmuxMobileTerminalKit
import Foundation

struct TerminalShortcutRowActions {
    let setEnabled: (ToolbarItemID, Bool) -> Void
    let removeCustomAction: (UUID) -> Void
    let editCustomAction: (CustomToolbarAction) -> Void
}
#endif
