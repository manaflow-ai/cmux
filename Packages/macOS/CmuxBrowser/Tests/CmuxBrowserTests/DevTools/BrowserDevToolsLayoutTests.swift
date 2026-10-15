import CoreGraphics
import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserDevToolsLayoutTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1001, height: 801)

    @Test func closedOrWindowedToolsLeaveThePageTheWholePane() {
        let closed = BrowserDevToolsLayout(dock: .bottom).frames(in: bounds, devToolsDocked: false)
        #expect(closed == BrowserDevToolsLayoutFrames(page: bounds, devTools: .zero, line: .zero, grab: .zero))
        let windowed = BrowserDevToolsLayout(dock: .window).frames(in: bounds, devToolsDocked: true)
        #expect(windowed.page == bounds)
        #expect(windowed.devTools == .zero)
    }

    @Test func bottomDockSplitsHeightAroundAOnePointLine() {
        let frames = BrowserDevToolsLayout(dock: .bottom, bottomFraction: 0.4).frames(in: bounds, devToolsDocked: true)
        #expect(frames.devTools == CGRect(x: 0, y: 0, width: 1001, height: 320))
        #expect(frames.line == CGRect(x: 0, y: 320, width: 1001, height: 1))
        #expect(frames.page == CGRect(x: 0, y: 321, width: 1001, height: 480))
        #expect(frames.grab == CGRect(x: 0, y: 317, width: 1001, height: 7))
    }

    @Test func sideDocksSplitWidth() {
        let right = BrowserDevToolsLayout(dock: .right, sideFraction: 0.5).frames(in: bounds, devToolsDocked: true)
        #expect(right.devTools == CGRect(x: 501, y: 0, width: 500, height: 801))
        #expect(right.line == CGRect(x: 500, y: 0, width: 1, height: 801))
        #expect(right.page == CGRect(x: 0, y: 0, width: 500, height: 801))
        let left = BrowserDevToolsLayout(dock: .left, sideFraction: 0.5).frames(in: bounds, devToolsDocked: true)
        #expect(left.devTools == CGRect(x: 0, y: 0, width: 500, height: 801))
        #expect(left.line == CGRect(x: 500, y: 0, width: 1, height: 801))
        #expect(left.page == CGRect(x: 501, y: 0, width: 500, height: 801))
    }

    @Test func extentKeepsMinimumsAndSplitsTinyPanes() {
        #expect(BrowserDevToolsLayout.devToolsExtent(fraction: 0.01, extent: 1001) == 120)
        #expect(BrowserDevToolsLayout.devToolsExtent(fraction: 0.99, extent: 1001) == 920)
        #expect(BrowserDevToolsLayout.devToolsExtent(fraction: 0.9, extent: 101) == 50)
    }

    @Test func draggingTheDividerUpdatesTheCurrentDockFraction() {
        var layout = BrowserDevToolsLayout(dock: .bottom)
        layout.dragDivider(to: CGPoint(x: 10, y: 500), in: bounds)
        #expect(abs(layout.bottomFraction - 0.625) < 0.0001)
        #expect(layout.sideFraction == 0.45)
        layout.dock = .right
        layout.dragDivider(to: CGPoint(x: 800, y: 10), in: bounds)
        #expect(abs(layout.sideFraction - 0.201) < 0.0001)
        layout.dock = .left
        layout.dragDivider(to: CGPoint(x: 5, y: 10), in: bounds)
        #expect(abs(layout.sideFraction - 0.12) < 0.0001)
    }

    @Test func forkSideValuesMapToDocks() {
        #expect(BrowserDevToolsDock(forkSide: 0) == .window)
        #expect(BrowserDevToolsDock(forkSide: 1) == .left)
        #expect(BrowserDevToolsDock(forkSide: 2) == .bottom)
        #expect(BrowserDevToolsDock(forkSide: 3) == .right)
        #expect(BrowserDevToolsDock(forkSide: 4) == nil)
        #expect(BrowserDevToolsDock.left.isSide && BrowserDevToolsDock.right.isSide)
        #expect(!BrowserDevToolsDock.bottom.isSide && !BrowserDevToolsDock.window.isDocked)
    }

    @MainActor
    @Test func storeRoundTripsAndRejectsInvalidValues() throws {
        let suite = "BrowserDevToolsLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowserDevToolsLayoutStore(defaults: defaults)
        #expect(store.load() == BrowserDevToolsLayout())
        store.save(BrowserDevToolsLayout(dock: .right, bottomFraction: 0.3, sideFraction: 0.6))
        #expect(store.load() == BrowserDevToolsLayout(dock: .right, bottomFraction: 0.3, sideFraction: 0.6))
        defaults.set(["dock": "sideways", "bottom": 2.0, "side": -1.0], forKey: BrowserDevToolsLayoutStore.defaultsKey)
        #expect(store.load() == BrowserDevToolsLayout())
    }
}
