import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar

// Tests read a row's controls by name. Each read makes the control when the row has not (`RowControlSlot`), so these
// live in the test target only: a production read would make every row's hidden controls again (REOPEN-F7, #34756
// review). Production code uses the slots.
extension WorkspaceRowView {
    var closeButton: SidebarIconButton { closeSlot.control(in: self) }
    var moreButton: OverflowButton { moreSlot.control(in: self) }
    var pinButton: SidebarIconButton { pinSlot.control(in: self) }
    var treeFoldButton: SidebarIconButton { treeFoldSlot.control(in: self) }
    var audioButton: SidebarIconButton { audioSlot.control(in: self) }
}
