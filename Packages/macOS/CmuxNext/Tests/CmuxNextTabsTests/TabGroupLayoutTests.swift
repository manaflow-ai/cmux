import CoreGraphics
import Testing
@testable import CmuxNextTabs

private func tab(_ id: String, group: String? = nil, pinned: Bool = false) -> TabItem {
    TabItem(id: TabID(id), title: id, isPinned: pinned, groupID: group.map { TabGroupID($0) })
}

