#if os(iOS)
@testable import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit

/// The Feed's filter menu sits in the toolbar over a list a busy Mac changes many times a second.
/// It read every event (and every workspace) in its body, so each Feed change built it again, on
/// the main thread, while the person scrolled. A Feed change that moves nothing the menu shows (the
/// filter, the mutes, whether anything is unread) builds neither the menu nor its Mark All Read
/// button (FEED-5).
@MainActor
@Suite(.serialized) struct FeedMenuEvaluationTests {
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    @Test func feedChangesThatMoveNothingItShowsBuildNoMenu() {
        let store = FeedStore(items: (0..<30).map { FeedStoreChurnTests.item("e\($0)", ago: Double($0)) })
        let menu = FeedFilterMenu(store: store, clearFailure: .constant(nil), markFailure: .constant(nil))
            .environment(AppStore.mock())
        let host = UIHostingController(rootView: menu)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 120))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<5 { settle() }
        let probe = FeedMenuProbe.shared
        let menus = probe.menuBodies, buttons = probe.markAllBodies
        #expect(menus > 0, "the menu was never built")
        #expect(store.hasUnread)
        for index in 0..<50 {
            store.upsert(FeedStoreChurnTests.item("n\(index)", ago: -Double(index)), atTop: true)
            settle()
        }
        #expect(store.visibleItems.count == 80)
        #expect(probe.menuBodies == menus, "50 new events built the filter menu \(probe.menuBodies - menus) times")
        #expect(probe.markAllBodies == buttons, "50 new events built Mark All Read \(probe.markAllBodies - buttons) times")
    }
}
#endif
