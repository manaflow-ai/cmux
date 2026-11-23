#if os(iOS) && DEBUG
import CmuxMobileDesign
import SwiftUI
import Testing
import UIKit

/// The frame-shift measure (``PagedListProbe/frameShift``) judges what the screen shows: one sample
/// per committed frame, not one per layout pass. A pass can run while the list is mid-placement (SwiftUI
/// gives the collection its bounds before its center, so one pass saw Home's list at (-201, -437) and
/// counted a 437 pt move no frame ever drew; HomeStressUITests at 696ff05). A jump that draws, even for
/// one frame and with no layout pass of the list, must still count in full.
@MainActor
@Suite(.serialized) struct PagedListCommitShiftTests {
    struct Row: Identifiable, Equatable {
        let id: Int
        var tall = false
        /// Taller than the list: alone on screen when it fills it.
        var huge: CGFloat?
    }

    /// The rows, which a test changes in place (a row that grows, as a Chief that starts typing).
    @Observable final class Rows {
        var items: [Row]
        init(_ items: [Row] = (0 ..< 200).map { Row(id: $0) }) { self.items = items }
    }

    private struct Screen: View {
        let rows: Rows
        let probe: PagedListProbe

        var body: some View {
            PagedList(direction: .down, items: rows.items, phase: .loaded, edge: .end, loadMore: {}, retry: {}) { row in
                Text("Row \(row.id)").frame(maxWidth: .infinity, minHeight: row.huge ?? (row.tall ? 82 : 60), alignment: .leading)
            }
            .pagedIdentifier("commit.list")
            .pagedProbe(probe)
        }
    }

    final class Seen {
        var shifts: [CGFloat] = []
        /// The drawn measure's samples (``PagedListProbe/drawnShift``).
        var drawn: [CGFloat] = []
        var drawnWorst: CGFloat { drawn.map(abs).max() ?? 0 }
        var worst: CGFloat { shifts.map(abs).max() ?? 0 }
    }

    private struct Hosted {
        let window: UIWindow
        let list: UICollectionView
        let seen: Seen
        let rows: Rows
        /// A plain view holding the list's host. A transform on it moves the list on screen with no
        /// layout pass and no safe-area change (SwiftUI and the window put back a transform on the
        /// collection or the root view, steps 797372f0 and 93049c31; moving it under a safe area
        /// changes the list's insets, which the list explains as an edge's move, steps 69902ff8 and
        /// d25910e3: so it sits clear of them).
        let container: UIView
    }

    private func host(rows initial: [Row]? = nil) throws -> Hosted {
        let seen = Seen()
        let probe = PagedListProbe()
        probe.frameShift = { seen.shifts.append($0) }
        probe.drawnShift = { shift, _ in seen.drawn.append(shift) }
        let rows = initial.map(Rows.init) ?? Rows()
        let list = Screen(rows: rows, probe: probe)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        let container = UIView(frame: root.view.bounds)
        container.autoresizingMask = []
        root.view.addSubview(container)
        let hosting = UIHostingController(rootView: list)
        root.addChild(hosting)
        hosting.view.frame = container.bounds
        container.addSubview(hosting.view)
        hosting.didMove(toParent: root)
        window.rootViewController = root
        // In the middle of the window, clear of its safe areas: a move of the holder changes no
        // inset, so nothing explains it as an edge's or a keyboard's move.
        container.frame = CGRect(x: 0, y: 200, width: window.bounds.width, height: 420)
        hosting.view.frame = container.bounds
        window.makeKeyAndVisible()
        let found = try #require(drain { () -> UICollectionView? in
            guard let view = window.firstCollection(identifier: "commit.list"), !view.indexPathsForVisibleItems.isEmpty else { return nil }
            return view
        }, "the list showed no rows")
        settle()
        seen.shifts = []
        seen.drawn = []
        return Hosted(window: window, list: found, seen: seen, rows: rows, container: container)
    }

    /// A row being read that moves on screen and stays there is a shift of its full size, even when
    /// nothing lays the list out again (its container moved it).
    @Test func aJumpThatDrawsCountsInFull() throws {
        let hosted = try host()
        defer { hosted.window.isHidden = true }
        hosted.container.transform = CGAffineTransform(translationX: 0, y: 10)
        settle()
        #expect(abs(hosted.seen.worst - 10) < 0.5, "a drawn 10 pt jump measured \(hosted.seen.shifts)")
    }

    /// A jump drawn for one frame and undone in the next counts twice: there and back.
    @Test func aOneFrameJumpCountsThereAndBack() throws {
        let hosted = try host()
        defer { hosted.window.isHidden = true }
        hosted.container.transform = CGAffineTransform(translationX: 0, y: 10)
        turn()
        hosted.container.transform = .identity
        settle()
        let big = hosted.seen.shifts.filter { abs($0) > 0.5 }
        #expect(big.count == 2 && abs(abs(big[0]) - 10) < 0.5 && abs(abs(big[1]) - 10) < 0.5,
                "a one-frame 10 pt jump measured \(hosted.seen.shifts)")
    }

    /// The list placed somewhere else in the middle of a layout pass and put back before the frame
    /// is committed never draws there: no shift.
    @Test func aMidPassPlacementUndoneBeforeTheCommitIsNoShift() throws {
        let hosted = try host()
        defer { hosted.window.isHidden = true }
        let list = hosted.list
        let center = list.center
        list.center = CGPoint(x: center.x - 201, y: center.y - 437)
        list.setNeedsLayout()
        list.layoutIfNeeded()
        list.center = center
        list.setNeedsLayout()
        list.layoutIfNeeded()
        settle()
        #expect(hosted.seen.worst <= 0.5, "a placement no frame drew measured \(hosted.seen.shifts)")
    }


    /// With the reader straddling the top edge as above, a 22 pt move of everything read (both edges
    /// of the row being read, and the row after it) still counts in full.
    @Test func aMoveOfEverythingReadCountsWhileTheReaderStraddlesTheEdge() throws {
        let hosted = try host()
        defer { hosted.window.isHidden = true }
        let list = hosted.list
        list.setContentOffset(CGPoint(x: 0, y: 10 * 60 + 20 - list.adjustedContentInset.top), animated: false)
        settle()
        hosted.seen.shifts = []
        hosted.container.transform = CGAffineTransform(translationX: 0, y: 22)
        settle()
        #expect(abs(hosted.seen.worst - 22) < 0.5, "a 22 pt move of everything read measured \(hosted.seen.shifts)")
    }




    private func top(of item: Int, in list: UICollectionView) -> CGFloat? {
        guard let attributes = list.layoutAttributesForItem(at: IndexPath(item: item, section: 0)) else { return nil }
        return list.convert(attributes.frame.origin, to: nil).y
    }




    /// The SwiftUI wiring: a change to the screen's rows reaches the list (its row count and a row's
    /// height). The anchor and probe cases run on the controller itself (PagedListAnchorDirectTests);
    /// this one proves what they skip.
    @Test func aChangeToTheScreensRowsReachesTheList() throws {
        let hosted = try host()
        defer { hosted.window.isHidden = true }
        let list = hosted.list
        #expect(hosted.window.isKeyWindow, "the host window is not key")
        let count = list.numberOfItems(inSection: 0)
        hosted.rows.items.insert(Row(id: 1000), at: 3)
        hosted.rows.items[0].tall = true
        settle()
        #expect(list.numberOfItems(inSection: 0) == count + 1, "the insert did not reach the list: \(list.numberOfItems(inSection: 0)) rows, model \(hosted.rows.items.count)")
        let height = list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame.height ?? -1
        // Known gap of the unit host, not of PagedList: after an update the cell's new content asks
        // for its new height, yet UIKit never asks the cell again in this host (diagnosis step
        // c1561c63: the model row and the content's fitting size read 82 while the layout and the cell
        // stay at 60, also after invalidateLayout and a scroll away and back). The stress UI suite,
        // where changes land, judges anchoring. Fails the day the host lands the grow: then drop this.
        withKnownIssue("the unit host does not re-size a reconfigured hosted cell (step c1561c63)") {
            #expect(abs(height - 82) < 0.5, "the grow did not reach the list: row 0 measured \(height) pt")
        }
    }

    /// One run loop turn: the frame so far is committed.
    private func turn() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    private func settle() {
        for _ in 0 ..< 15 { turn() }
    }

    private func drain<T>(until value: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let found = value() { return found }
            turn()
        }
        return value()
    }
}

private extension UIView {
    func firstCollection(identifier: String) -> UICollectionView? {
        if let list = self as? UICollectionView, list.accessibilityIdentifier == identifier { return list }
        for child in subviews {
            if let found = child.firstCollection(identifier: identifier) { return found }
        }
        return nil
    }
}
#endif
