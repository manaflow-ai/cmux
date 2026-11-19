#if os(iOS)
import CmuxMobileDesign
import Foundation
import SwiftUI
import Testing
import UIKit

/// PagedList's frame-shift measure (the stress bench's gate, ``PagedListProbe/frameShift``) and the
/// bars over a list: when the navigation bar's search drawer opens or closes at the top of a list
/// (UIKit's own snap, set off by the person's scroll), the list's top inset changes and UIKit moves
/// the offset with it, so the rows go with the bar's edge. That is not a shift of what is read
/// (Home at 5c0a2fe: 60 pt at the top, step 988db9f6). A row that moves beyond the bar's edge in
/// the same pass still is: the measure subtracts the inset's change only.
@MainActor
@Suite(.serialized) struct PagedListChromeShiftTests {
    struct Item: Identifiable, Equatable, Sendable {
        let id: Int
    }

    final class Shifts {
        var values: [CGFloat] = []
        var worst: CGFloat { values.map(abs).max() ?? 0 }
    }

    private func host() throws -> (UIWindow, UICollectionView, Shifts) {
        let shifts = Shifts()
        let probe = PagedListProbe()
        probe.frameShift = { shifts.values.append($0) }
        let items = (0..<200).map(Item.init)
        let list = PagedList(direction: .down, items: items, phase: .loaded, edge: .end, loadMore: {}, retry: {}) { item in
            Text("Row \(item.id)").frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        }
        .pagedIdentifier("chrome.list")
        .pagedProbe(probe)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: list)
        window.makeKeyAndVisible()
        let deadline = Date().addingTimeInterval(5)
        var found: UICollectionView?
        while found == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            found = window.firstList("chrome.list").flatMap { $0.indexPathsForVisibleItems.isEmpty ? nil : $0 }
        }
        let collection = try #require(found, "the list showed no rows")
        settle(collection)
        return (window, collection, shifts)
    }

    /// One layout pass after `change`, with the shifts it measured.
    private func pass(_ collection: UICollectionView, _ shifts: Shifts, _ change: () -> Void) -> CGFloat {
        settle(collection)
        shifts.values = []
        change()
        collection.setNeedsLayout()
        collection.layoutIfNeeded()
        return shifts.worst
    }

    private func settle(_ collection: UICollectionView) {
        for _ in 0 ..< 10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        collection.setNeedsLayout()
        collection.layoutIfNeeded()
    }

    /// The drawer opens at the top: the inset grows 60 pt and the offset moves with it.
    @Test func theBarsOwnMoveIsNotAShift() throws {
        let (window, collection, shifts) = try host()
        defer { window.isHidden = true }
        let worst = pass(collection, shifts) {
            collection.contentInset.top += 60
            collection.contentOffset.y -= 60
        }
        #expect(worst <= 0.5, "the drawer's own move counted as a \(worst) pt shift")
    }

    /// The same inset change with the rows moving 30 pt more than the bar's edge: still a shift.
    @Test func aRealShiftDuringTheBarsMoveIsStillCaught() throws {
        let (window, collection, shifts) = try host()
        defer { window.isHidden = true }
        let worst = pass(collection, shifts) {
            collection.contentInset.top += 60
            collection.contentOffset.y -= 90
        }
        #expect(abs(worst - 30) <= 1, "measured \(worst) pt for a 30 pt shift beyond the bar's move")
    }

    /// No inset change: a move of the rows the scroll does not explain is a shift, as before.
    @Test func aShiftWithoutTheBarsIsCaught() throws {
        let (window, collection, shifts) = try host()
        defer { window.isHidden = true }
        let worst = pass(collection, shifts) { collection.contentOffset.y -= 30 }
        #expect(abs(worst - 30) <= 1, "measured \(worst) pt for a 30 pt shift")
    }
}

private extension UIView {
    func firstList(_ identifier: String) -> UICollectionView? {
        for view in subviews {
            if let list = view as? UICollectionView, list.accessibilityIdentifier == identifier { return list }
            if let found = view.firstList(identifier) { return found }
        }
        return nil
    }
}
#endif
