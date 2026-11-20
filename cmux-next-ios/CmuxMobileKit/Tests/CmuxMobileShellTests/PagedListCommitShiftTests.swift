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
    struct Row: Identifiable, Equatable { let id: Int }

    final class Seen {
        var shifts: [CGFloat] = []
        var worst: CGFloat { shifts.map(abs).max() ?? 0 }
    }

    private struct Hosted {
        let window: UIWindow
        let list: UICollectionView
        let seen: Seen
        /// The hosting controller's view: what moves the list without SwiftUI putting it back.
        var container: UIView { window.rootViewController?.view ?? list }
    }

    private func host() throws -> Hosted {
        let seen = Seen()
        let probe = PagedListProbe()
        probe.frameShift = { seen.shifts.append($0) }
        let list = PagedList(direction: .down, items: (0 ..< 200).map(Row.init), phase: .loaded, edge: .end,
                             loadMore: {}, retry: {}) { row in
            Text("Row \(row.id)").frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        }
        .pagedIdentifier("commit.list")
        .pagedProbe(probe)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: list)
        window.makeKeyAndVisible()
        let found = try #require(drain { () -> UICollectionView? in
            guard let view = window.firstCollection(identifier: "commit.list"), !view.indexPathsForVisibleItems.isEmpty else { return nil }
            return view
        }, "the list showed no rows")
        settle()
        seen.shifts = []
        return Hosted(window: window, list: found, seen: seen)
    }

    /// A row being read that moves on screen and stays there is a shift of its full size, even when
    /// nothing lays the list out again (its container moved it; the screen's root view here, which
    /// SwiftUI does not place, unlike the collection itself).
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
