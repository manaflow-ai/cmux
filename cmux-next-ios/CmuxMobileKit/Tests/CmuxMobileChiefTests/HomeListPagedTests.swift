#if os(iOS) && DEBUG
import CmuxMobileDesign
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileChief

/// Aziz's recording 2026-11-18 (about 25 Chiefs typing, about 45 agents): Home's list hitched while
/// he scrolled, because every change of the Mac's list rebuilt every row's values and animated the
/// whole `List` on the list's revision. Home is now the shared ``PagedList``: one Chief that starts
/// typing redraws that row alone (HOME-8), and a burst of changes before the next frame lands as one
/// apply (HOME-14).
@MainActor
@Suite(.serialized) struct HomeListPagedTests {
    /// Home in a window, its list probed; `feed` holds the list rig's rows.
    private struct Hosted {
        let window: UIWindow
        let feed: MacHomeFeed
        var applies: [(reconfigured: [AnyHashable], rowsChanged: Bool)] { recorder.applies }
        let recorder: Recorder
    }

    final class Recorder {
        var applies: [(reconfigured: [AnyHashable], rowsChanged: Bool)] = []
        var slides: [Int] = []
    }

    private func host(rows: Int) throws -> Hosted {
        let feed = MacHomeFeed()
        feed.seedStressRows(count: rows, macID: "mac-studio")
        let mac = ChiefSession(backend: ChiefOfflineBackend(), clock: ImmediateClock())
        let cloud = ChiefSession(backend: ChiefOfflineBackend(), clock: ImmediateClock())
        let sources = ChiefSources(mac: mac, cloud: cloud, selection: UserDefaults(suiteName: "home-paged-\(UUID())")!)
        let recorder = Recorder()
        let probe = PagedListProbe()
        probe.applied = { reconfigured, rowsChanged in recorder.applies.append((reconfigured, rowsChanged)) }
        probe.slid = { frames in recorder.slides.append(frames) }
        var home = ConversationsHome(store: AppStore(teams: [], activeTeamID: "", workspaces: [], feed: []),
                                     sources: sources, feed: feed, open: { _ in }) {
            ToolbarItem(placement: .topBarLeading) { EmptyView() }
        }
        home.listProbe = probe
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: NavigationStack { home })
        window.makeKeyAndVisible()
        _ = try #require(drain { () -> UICollectionView? in
            guard let list = window.firstList(identifier: "home.list"), !list.indexPathsForVisibleItems.isEmpty else { return nil }
            return list
        }, "Home's list showed no rows")
        settle()
        return Hosted(window: window, feed: feed, recorder: recorder)
    }

    /// HOME-8: a Chief that starts or stops typing redraws its own row and nothing else, with no
    /// row coming, going or moving.
    @Test func oneChiefTypingReconfiguresOnlyItsRow() throws {
        let home = try host(rows: 120)
        defer { home.window.isHidden = true }
        let before = home.feed.rows ?? []
        home.recorder.applies = []
        // An odd tick: a typing change in place (no new message).
        home.feed.stressLiveTick(1, changes: 1)
        settle()
        let after = home.feed.rows ?? []
        let changed = zip(before, after).filter { $0 != $1 }.map(\.1)
        let row = try #require(changed.first, "the tick changed no row")
        #expect(changed.count == 1)
        let expected: AnyHashable = row.isPinned ? "home:tiles" : row.id
        #expect(home.applies.count == 1, "applies: \(home.applies.count)")
        #expect(home.applies.first?.reconfigured == [expected], "reconfigured \(home.applies.first?.reconfigured ?? [])")
        #expect(home.applies.first?.rowsChanged == false, "a typing change moved rows")
    }

    /// A Chief that posts while the reader is at the top slides in at the top of the rows, under the
    /// pinned grid, on the list's spring (more than one frame): the grid, a header, never holds the
    /// rows in place (review of 1415658: with pins the row was pushed in, in one frame).
    @Test func aNewMessageAtTheTopSlidesInUnderThePins() throws {
        let home = try host(rows: 120)
        defer { home.window.isHidden = true }
        let rows = home.feed.rows ?? []
        #expect(rows.prefix(4).allSatisfy(\.isPinned), "the rig pins four rows")
        let firstUnpinned = try #require(rows.first { !$0.isPinned }).id
        home.recorder.slides = []
        // An even tick: a new message, its Chief moves to the top of the unpinned rows.
        home.feed.stressLiveTick(2, changes: 1)
        let deadline = Date().addingTimeInterval(3)
        while home.recorder.slides.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let moved = try #require(home.feed.rows?.first { !$0.isPinned }).id
        #expect(moved != firstUnpinned, "the tick moved no Chief to the top")
        let frames = try #require(home.recorder.slides.first, "no slide")
        #expect(frames > 1, "the new row jumped in (\(frames) frame)")
    }

    /// HOME-14: a burst of 1000 changes before the next frame (a busy Mac's events while the main
    /// thread was busy) lands as one apply, not one per change.
    @Test func aBurstOfAThousandChangesIsOneApply() throws {
        let home = try host(rows: 300)
        defer { home.window.isHidden = true }
        home.recorder.applies = []
        for tick in 1...1000 { home.feed.stressLiveTick(tick, changes: 1) }
        settle()
        #expect(home.applies.count == 1, "\(home.applies.count) applies for one burst")
    }

    /// A pass whose inputs did not change builds nothing; one row's change builds one row's values.
    @Test func itemsRebuildOnlyTheChangedRow() throws {
        let feed = MacHomeFeed()
        feed.seedStressRows(count: 60, macID: "mac-studio")
        let memo = MacHomeList.Memo()
        let items = HomeListItems()
        let context = HomeListItems.RowContext(macTag: "Mac Studio", macChiefConversation: nil, macChiefListID: nil,
                                               macAvatar: "C", cloudReady: false, day: Date())
        func pass() -> [HomeItem] {
            let list = memo.list(feed.rows ?? [], query: "", unreadOnly: false,
                                 version: .init(rows: feed.rowsRevision), change: feed.lastChange)
            return items.items(list, listRevision: memo.revision, context: context, extras: .init())
        }
        let first = pass()
        #expect(items.rowModelBuilds == 60)
        _ = pass()
        #expect(items.assemblies == 1, "a pass with nothing new assembled the items again")
        #expect(items.rowModelBuilds == 60)
        feed.stressLiveTick(1, changes: 1)
        let second = pass()
        #expect(items.rowModelBuilds == 61, "one changed row built \(items.rowModelBuilds - 60) row models")
        #expect(first.map(\.id) == second.map(\.id))
        #expect(zip(first, second).filter { $0 != $1 }.count == 1)
    }

    private func settle() {
        for _ in 0 ..< 15 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func drain<T>(until value: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let found = value() { return found }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return value()
    }
}

private extension UIView {
    func firstList(identifier: String) -> UICollectionView? {
        for view in subviews {
            if let list = view as? UICollectionView, list.accessibilityIdentifier == identifier { return list }
            if let found = view.firstList(identifier: identifier) { return found }
        }
        return nil
    }
}
#endif
