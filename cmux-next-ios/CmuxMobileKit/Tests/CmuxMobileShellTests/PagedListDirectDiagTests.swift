#if os(iOS) && DEBUG
@testable import CmuxMobileDesign
import SwiftUI
import Testing
import UIKit

/// Diagnosis only (never lands): why a change after the first render does not land in the direct
/// host (step 1a53607a). Every reading goes out through Issue.record, so the step's failures list
/// carries it.
@MainActor
@Suite(.serialized) struct PagedListDirectDiagTests {
    typealias Host = PagedListAnchorDirectTests.Host
    typealias Row = PagedListAnchorDirectTests.Row

    private func state(_ host: Host, _ item: Int, _ label: String) -> String {
        let path = IndexPath(item: item, section: 0)
        let attributes = host.list.layoutAttributesForItem(at: path)?.frame ?? .null
        let cell = host.list.cellForItem(at: path)
        let fitting = cell?.contentView.systemLayoutSizeFitting(CGSize(width: host.list.bounds.width, height: 0),
                                                               withHorizontalFittingPriority: .required,
                                                               verticalFittingPriority: .fittingSizeLevel).height ?? -1
        return "\(label): follows=\(host.controller.followsNewest) applies=\(host.controller.applies) "
            + "model[\(item)].height=\(host.rows[item].height) attrs=\(attributes) cell=\(cell.map { "\($0.frame)" } ?? "nil") "
            + "contentFits=\(fitting) offset=\(host.list.contentOffset.y) window.scene=\(host.window.windowScene != nil) "
            + "key=\(host.window.isKeyWindow) visible=\(host.list.indexPathsForVisibleItems.map(\.item).sorted().prefix(4))"
    }

    @Test func diagGrow() {
        let host = Host()
        defer { host.close() }
        host.scroll(toTopOf: 10, plus: 20)
        var lines = [state(host, 10, "before")]
        host.apply { $0[10].height = 82 }
        lines.append(state(host, 10, "after apply+settle"))
        host.list.collectionViewLayout.invalidateLayout()
        host.settle()
        lines.append(state(host, 10, "after invalidateLayout"))
        lines.append("cell configured again: dataSource item=\(String(describing: (host.list.dataSource as? UICollectionViewDiffableDataSource<Int, PagedListCellID<Int>>)?.itemIdentifier(for: IndexPath(item: 10, section: 0))))")
        // A fresh cell: scroll row 10 out of view and back.
        host.scroll(toTopOf: 60)
        host.scroll(toTopOf: 10, plus: 20)
        lines.append(state(host, 10, "after scroll away and back"))
        Issue.record(Comment(rawValue: "DIAG-GROW\n" + lines.joined(separator: "\n")))
    }

    @Test func diagRemoveAbove() {
        let host = Host()
        defer { host.close() }
        host.scroll(toTopOf: 20)
        var lines = [state(host, 20, "before")]
        host.apply { $0.removeFirst(10) }
        lines.append(state(host, 10, "after removeFirst(10), row 20 now item 10"))
        Issue.record(Comment(rawValue: "DIAG-REMOVE\n" + lines.joined(separator: "\n")))
    }
}
#endif
