#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileFeed
@testable import CmuxMobileLive

/// Audit 17 read-back: the real Feed list (`FeedCollection`, the rows the Feed tab draws) while a
/// waiting chat's open asks fail to load once, then load. Written against the hub's and the Feed's
/// public wiring and the app's own retry delays only, so the same test runs on the old code
/// (`lane/ios-pending-ask-seed-old-detector`), where the first read's failure was dropped.
/// Saves `feed-seed-1s.png` (the first read failed) and `feed-seed-4s.png` (after the first
/// retry, 2 s later), and a log of what the Feed held, as attachments.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct FeedSeedRetryCaptureTests {
    struct Feed: View {
        let store: FeedStore
        @State var context: FeedRowContext
        @State var swipe = FeedSwipeCoordinator()
        @State var control = FeedListControl()

        var body: some View {
            FeedCollection(items: store.visibleItems, context: context, swipe: swipe, control: control,
                           header: AnyView(EmptyView()), headerSignature: AnyHashable(0), headerContent: AnyHashable(0))
        }
    }

    @Test func captureTheFeedWhileTheAsksFailToLoadThenLoad() async throws {
        let failures = FeedSeedRetryTests.Failures(1)
        let hub = AcpmuxHub()
        let store = FeedStore(items: [])
        let feed = LiveFeed(store: store, hub: hub, place: { _ in nil })
        store.actions = feed
        hub.onWatchEvent = { [weak hub] event in
            guard let hub else { return }
            feed.handle(event, sessions: hub.sessions)
        }
        defer { withExtendedLifetime(hub) {} }

        let bounds = CGRect(x: 0, y: 0, width: 402, height: 500)
        let window = UIWindow(frame: bounds)
        window.rootViewController = UIHostingController(rootView: Feed(store: store, context: FeedRowContext(store: store)))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        var log: [String] = []
        func capture(_ name: String) {
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
                UIColor.systemBackground.setFill()
                UIRectFill(bounds)
                window.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            if let png = image.pngData() { Attachment.record(Array(png), named: "\(name).png") }
            let rows = store.visibleItems.map { "\($0.id) needsYou=\($0.needsYou) \"\($0.markdown.prefix(90))\"" }
            log.append("\(name): reads=\(failures.reads) needsYou=\(store.needsYouIDs) rows=\(rows)")
        }
        func wait(_ seconds: Double) async {
            try? await Task.sleep(for: .seconds(seconds)) // test: the capture times, against the app's retry delays
        }

        let start = ContinuousClock.now
        await hub.bind(try await FeedSeedRetryTests.mac(failing: failures).openChannel(service: "acpmux", args: [:]))
        await wait(1 - (ContinuousClock.now - start) / .seconds(1))
        capture("feed-seed-1s")
        await wait(4 - (ContinuousClock.now - start) / .seconds(1))
        capture("feed-seed-4s")
        Attachment.record(log.joined(separator: "\n"), named: "feed-seed-capture.txt")
        print("FEEDSEEDCAPTURE " + log.joined(separator: " | "))

        #expect(store.item(id: "ask-perm")?.needsYou == true, "the card shows after the first retry (\(log))")
    }
}
#endif
