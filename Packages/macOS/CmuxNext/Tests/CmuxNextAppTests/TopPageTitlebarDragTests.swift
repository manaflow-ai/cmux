import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// A top page (Import history's "Bring your history", History, Settings) fills the main pane with
/// no tab strip above it, so its top row is the window's title bar, like the sidebar header beside
/// it. The window moved only from the sidebar's top strip: a press over the page's top row landed
/// on its web view and stayed put (https://github.com/manaflow-ai/cmux/issues/36897).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TopPageTitlebarDragTests {
    @Test(arguments: [InternalPageID.importHistory, .history])
    func aPressInATopPagesTopRowMovesTheWindow(_ id: InternalPageID) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            try #require(TopPages.show(.page(id), services: services) != nil, "\(id.rawValue) did not show as a top page")
            try #require(controller.shownTopPage == .page(id))
            let page = try #require(controller.topPages.views[.page(id)])
            window.contentView?.layoutSubtreeIfNeeded()

            let band = TitlebarDragPolicy.bandRect(in: window)
            try #require(band.height > 0, "the window has a titlebar band")
            let frameView = try #require(window.contentView?.superview)
            let shown = page.convert(page.bounds, to: nil)
            // The band's rows over the page: only the points a press lands on the page at.
            let points = [band.maxY - 2, band.midY, band.minY + 2]
                .flatMap { y in stride(from: shown.minX + 4, to: shown.maxX - 4, by: 16).map { CGPoint(x: $0, y: y) } }
                .filter { frameView.hitTest(frameView.convert($0, from: nil))?.isDescendant(of: page) ?? false }
            try #require(!points.isEmpty, "the page reaches the window's top row (page \(shown), band \(band))")

            let staying = points.filter { TitlebarDragPolicy.decide(at: $0, in: window) != .movesWindow }
            #expect(staying.isEmpty, "a press over \(id.rawValue)'s top row stays put at \(staying)")
            // Below the top row the page keeps its presses.
            let below = CGPoint(x: shown.midX, y: shown.midY)
            #expect(TitlebarDragPolicy.decide(at: below, in: window) == .staysPut)
        }
    }
}
