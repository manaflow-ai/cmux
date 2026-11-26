#if os(iOS)
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileChief

/// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the f*** up and load
/// faster/percievably load faster". A read-back of Home's first frame after a relaunch: the real
/// `ConversationsHome` in a window over a list kept by the last run, no Mac link at all. The first
/// layout pass (the first frame, before any run loop turn) must already list the kept rows, not
/// "Connecting to <Mac>…" over an empty list. It saves that frame, and the one after the whole list lands, as PNGs and a
/// log as attachments.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct HomeFirstFrameReadBackTests {
    struct Home: View {
        let sources: ChiefSources
        let feed: MacHomeFeed
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [])

        var body: some View {
            NavigationStack {
                ConversationsHome(store: store, sources: sources, feed: feed, open: { _ in }) {
                    ToolbarItem(placement: .topBarLeading) { EmptyView() }
                }
            }
        }
    }

    @Test func readBackHomesFirstFrameOverKeptRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "home-first-frame-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = MacHomeRowsCache.key(account: "user-a", macID: "mac-1")
        // The last run kept 200 rows (the cache's limit) for this account's Mac.
        let writer = MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0))
        writer.save(key, rows: HomeKeptRowsTimingTests.rows(200))
        writer.flush()

        // A relaunch: a new cache (nothing in memory) and a Mac Chief that knows its Mac, no link.
        let cache = MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0))
        let feed = MacHomeFeed(rowsCache: cache, accountID: { "user-a" })
        let mac = ChiefSession(backend: ChiefOfflineBackend(), clock: ImmediateClock())
        let cloud = ChiefSession(backend: ChiefOfflineBackend(), clock: ImmediateClock())
        mac.macID = "mac-1"
        mac.macName = "cmux mini"
        let sources = ChiefSources(mac: mac, cloud: cloud, selection: UserDefaults(suiteName: "home-first-frame-\(UUID())")!)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: Home(sources: sources, feed: feed))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        var log: [String] = []
        func frame(_ name: String) -> Int {
            window.layoutIfNeeded()
            let list = window.firstHomeList()
            let items = list.map { list in (0 ..< list.numberOfSections).reduce(0) { $0 + list.numberOfItems(inSection: $1) } } ?? 0
            let note = HomeListNote.make(rows: feed.rows, homeMacID: "mac-1",
                                         macsMayExist: true, searching: false, failing: false)
            log.append("\(name): feed.rows=\(feed.rows?.count ?? -1) kept=\(feed.isShowingKeptRows) note=\(String(describing: note)) list.items=\(items)")
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let shot = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
                // The layer tree as drawn (a window snapshot is blank in a test host).
                UIColor.systemBackground.setFill()
                context.fill(window.bounds)
                window.layer.render(in: context.cgContext)
            }
            if let png = shot.pngData() { Attachment.record(png, named: "home-\(name).png") }
            return items
        }

        // The first frame: one layout pass, no run loop turn in between.
        let firstItems = frame("first-frame")
        let firstRows = feed.rows?.count
        // A frame after it: the whole kept list (200 rows) lands from its read off the main thread.
        let wholeList = await eventually { feed.rows?.count == 200 }
        _ = frame("whole-list")
        Attachment.record(log.joined(separator: "\n"), named: "home-first-frame-readback.txt")

        #expect(firstRows != nil, "the first frame has the kept rows on the feed")
        #expect(feed.isShowingKeptRows)
        #expect(HomeListNote.make(rows: feed.rows, homeMacID: "mac-1",
                                  macsMayExist: true, searching: false, failing: false) != .connecting)
        // The Chief pin and a note are at most a few items; the kept rows are many more.
        #expect(firstItems >= 10, "the first frame lists the kept rows (\(log.joined(separator: "; ")))")
        #expect(wholeList, "the whole kept list follows the head")
    }
}

private extension UIView {
    func firstHomeList() -> UICollectionView? {
        for view in subviews {
            if let match = view as? UICollectionView { return match }
            if let found = view.firstHomeList() { return found }
        }
        return nil
    }
}
#endif
