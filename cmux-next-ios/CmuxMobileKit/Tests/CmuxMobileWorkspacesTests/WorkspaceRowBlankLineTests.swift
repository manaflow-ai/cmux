#if os(iOS)
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileWorkspaces

/// A workspace row with nothing to say on line 2 (idle, no branch, no folder,
/// no Mac named) is the name line alone: as short as a compact row, with no
/// blank line under the name. Before, it kept an empty line 2 and the
/// two-line row's height.
@MainActor @Suite struct WorkspaceRowBlankLineTests {
    nonisolated static let sizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility3]

    private func workspace(branch: String? = nil, directory: String = "") -> Workspace {
        Workspace(id: "ws-bare", macID: "mac-1", title: "scratch", directory: directory, branch: branch,
                  tabs: [], lastActivityAt: Date(timeIntervalSince1970: 1_000_000))
    }

    private func height(_ row: WorkspaceRow, _ type: DynamicTypeSize) -> CGFloat {
        let host = UIHostingController(rootView: row.dynamicTypeSize(type))
        return host.sizeThatFits(in: CGSize(width: 390, height: 1000)).height
    }

    @Test(arguments: sizes) func blankIdleRowIsAsShortAsACompactRow(type: DynamicTypeSize) {
        let bare = height(WorkspaceRow(workspace: workspace(), status: .idle), type)
        let compact = height(WorkspaceRow(workspace: workspace(branch: "main"), status: .idle, compact: true), type)
        let twoLines = height(WorkspaceRow(workspace: workspace(branch: "main"), status: .idle), type)
        #expect(bare == compact, "blank row \(bare) pt, compact row \(compact) pt")
        #expect(bare < twoLines, "blank row \(bare) pt, two-line row \(twoLines) pt")
    }

    @Test func blankOfflineRowIsOneLineToo() {
        let bare = height(WorkspaceRow(workspace: workspace(), status: .offline), .large)
        let twoLines = height(WorkspaceRow(workspace: workspace(directory: "~/notes"), status: .offline), .large)
        #expect(bare < twoLines, "blank offline row \(bare) pt, two-line row \(twoLines) pt")
    }

    @Test func rowsWithSomethingToSayKeepLineTwo() {
        let twoLines = height(WorkspaceRow(workspace: workspace(branch: "main"), status: .idle), .large)
        // A Mac name alone, a folder alone, and every agent status have words.
        #expect(height(WorkspaceRow(workspace: workspace(), status: .idle, macName: "Mac Studio"), .large) == twoLines)
        #expect(height(WorkspaceRow(workspace: workspace(directory: "~"), status: .idle), .large) == twoLines)
        for status in [WorkspaceStatus.needsYou, .working, .done, .creating] {
            #expect(height(WorkspaceRow(workspace: workspace(), status: status), .large) == twoLines, "\(status)")
        }
    }

    /// The list's height cache shares one height per row shape: a blank row
    /// must not take the height a two-line row with the same icon measured.
    @Test func heightCacheKeepsBlankRowsApartFromTwoLineRows() {
        func item(_ ws: Workspace) -> WorkspacesListItem {
            .row(WorkspaceRowModel(workspace: ws, status: .idle, isStale: false, tracksMacData: false, canManage: true,
                                   canArrange: true, canDuplicate: true, canMoveUp: false, canMoveDown: false))
        }
        let cache = WorkspacesHeightCache()
        let placed = workspace(branch: "main")
        cache.store(.init(id: "ws-placed", item: item(placed)), width: 390, height: 60)
        let blank = cache.height(.init(id: "ws-bare", item: item(workspace())), width: 390)
        #expect(blank != 60, "a blank row took the two-line row's cached height")
    }
}
#endif
