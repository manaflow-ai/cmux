import AppKit
import Foundation
import Testing
@testable import CmuxNextBrowser

/// Docked DevTools geometry and DevTools events, without starting CEF.
@MainActor
@Suite struct CEFDevToolsTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    private func makeTab() -> CEFTab {
        let runtime = CEFRuntime.shared
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "dt"), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        return tab
    }

    // MARK: Layout

    @Test func closedDevToolsLeavesThePageTheWholePane() {
        let frames = CEFDevToolsLayout().frames(in: bounds, devToolsDocked: false)
        #expect(frames.page == bounds)
        #expect(frames.devTools == .zero)
        #expect(frames.grab == .zero)
    }

    @Test func bottomDockSplitsHeightWithADividerLine() {
        var layout = CEFDevToolsLayout()
        layout.dock = .bottom
        layout.bottomFraction = 0.5
        let frames = layout.frames(in: bounds, devToolsDocked: true)
        #expect(frames.devTools.minY == 0)
        #expect(frames.devTools.width == 1000)
        #expect(frames.line.minY == frames.devTools.maxY)
        #expect(frames.page.minY == frames.line.maxY)
        #expect(frames.page.maxY == 600)
        #expect(frames.page.height + frames.line.height + frames.devTools.height == 600)
        #expect(frames.grab.height == CEFDevToolsLayout.lineThickness + 2 * CEFDevToolsLayout.grabOutset)
    }

    @Test func rightDockSplitsWidth() {
        var layout = CEFDevToolsLayout()
        layout.dock = .right
        layout.rightFraction = 0.4
        let frames = layout.frames(in: bounds, devToolsDocked: true)
        #expect(frames.devTools.maxX == 1000)
        #expect(frames.devTools.height == 600)
        #expect(frames.page.minX == 0)
        #expect(frames.page.maxX == frames.line.minX)
        #expect(frames.line.maxX == frames.devTools.minX)
        #expect(abs(frames.devTools.width - 400) <= 1)
    }

    @Test func windowDockKeepsThePageWhole() {
        var layout = CEFDevToolsLayout()
        layout.dock = .window
        #expect(layout.frames(in: bounds, devToolsDocked: true).page == bounds)
    }

    @Test func dragKeepsBothSidesAboveTheirMinimums() {
        var layout = CEFDevToolsLayout()
        layout.dragDivider(to: CGPoint(x: 500, y: 590), in: bounds)
        var frames = layout.frames(in: bounds, devToolsDocked: true)
        #expect(frames.page.height >= CEFDevToolsLayout.minPage)
        layout.dragDivider(to: CGPoint(x: 500, y: 5), in: bounds)
        frames = layout.frames(in: bounds, devToolsDocked: true)
        #expect(frames.devTools.height >= CEFDevToolsLayout.minDevTools)
        layout.dragDivider(to: CGPoint(x: 500, y: 300), in: bounds)
        frames = layout.frames(in: bounds, devToolsDocked: true)
        #expect(abs(frames.devTools.height - 300) <= 1)
    }

    @Test func tinyPaneSplitsInHalf() {
        let small = CGRect(x: 0, y: 0, width: 150, height: 150)
        let frames = CEFDevToolsLayout().frames(in: small, devToolsDocked: true)
        #expect(frames.devTools.height > 0 && frames.page.height > 0)
        #expect(frames.page.height + frames.line.height + frames.devTools.height == 150)
    }

    @Test func rememberedLayoutRoundTripsThroughDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "CEFDevToolsTests-\(UUID().uuidString)"))
        defaults.set(["dock": "right", "bottom": 0.3, "right": 0.6], forKey: "CmuxNextBrowser.devToolsLayout")
        let layout = CEFDevToolsLayout.load(from: defaults)
        #expect(layout.dock == .right)
        #expect(layout.bottomFraction == 0.3)
        #expect(layout.rightFraction == 0.6)
        defaults.set(["dock": "sideways", "bottom": 7.0], forKey: "CmuxNextBrowser.devToolsLayout")
        #expect(CEFDevToolsLayout.load(from: defaults) == CEFDevToolsLayout())
    }

    // MARK: Events

    @Test func shimDevToolsEventsDecodeWithTheInspectedBrowser() {
        #expect(CEFShimEvent(kind: 20, browser: 7, request: 0, a: 0, b: 0, s1: "", s2: "") == .devToolsWillOpen(browser: 7))
        #expect(CEFShimEvent(kind: 21, browser: 7, request: 0, a: 9, b: 1, s1: "", s2: "")
            == .devToolsOpened(browser: 7, devTools: 9, docked: true))
        #expect(CEFShimEvent(kind: 22, browser: 7, request: 0, a: 9, b: 0, s1: "", s2: "") == .devToolsClosed(browser: 7, devTools: 9))
        #expect(CEFShimEvent.devToolsOpened(browser: 7, devTools: 9, docked: false).browserID == 7)
    }

    private final class Observer: BrowserDevToolsObserving {
        var changes: [(BrowserDevToolsState, Bool)] = []
        func browserTab(_ tab: any BrowserTab, devToolsDidChange state: BrowserDevToolsState, focused: Bool) {
            changes.append((state, focused))
        }
    }

    /// Opening DevTools never navigates the page or changes its URL or
    /// title: DevTools events only change the DevTools state, and the
    /// DevTools browser is never registered as a tab.
    @Test func devToolsNeverWritesIntoTheTabRecord() {
        let runtime = CEFRuntime.shared
        let tab = makeTab()
        let observer = Observer()
        tab.devToolsObserver = observer
        runtime.register(tab, browser: 4101)
        defer { runtime.tabsByBrowser[4101] = nil }
        tab.handle(.address(browser: 4101, url: "https://page.example/"))
        tab.handle(.title(browser: 4101, title: "Page"))
        runtime.handle(.devToolsOpened(browser: 4101, devTools: 4102, docked: true))
        #expect(runtime.tabsByBrowser[4102] == nil)
        // A stray event from the DevTools browser id reaches no tab.
        runtime.handle(.address(browser: 4102, url: "devtools://devtools/bundled/devtools_app.html"))
        runtime.handle(.title(browser: 4102, title: "DevTools"))
        #expect(tab.state.url?.absoluteString == "https://page.example/")
        #expect(tab.state.title == "Page")
        #expect(tab.devTools.isOpen)
        #expect(observer.changes.last?.1 == true)
        runtime.handle(.devToolsClosed(browser: 4101, devTools: 4102))
        #expect(!tab.devTools.isOpen)
        #expect(observer.changes.count == 2)
        #expect(observer.changes.last?.1 == false)
    }

    /// A docked DevTools host view sits beside the page in the content view.
    @Test func dockedDevToolsTakesItsFrameInTheContentView() {
        let tab = makeTab()
        let content = tab.container
        content.frame = bounds
        tab.devToolsController.layout.dock = .right
        tab.devToolsController.layout.rightFraction = 0.5
        let host = CEFHostView()
        let divider = CEFDevToolsDivider()
        content.addSubview(host)
        content.addSubview(divider)
        tab.devToolsController.views = (host, divider)
        tab.devToolsController.opened(browser: 5, docked: true)
        let frames = tab.devToolsController.frames(in: bounds)
        #expect(host.frame == frames.devTools)
        #expect(divider.frame == frames.grab)
        #expect(host.frame.width > 0 && host.frame.maxX == bounds.maxX)
        // The divider's grab area is a hole in the DevTools window.
        #expect(host.occlusionRects.count == 1)
        tab.devToolsController.closed(browser: 5)
        #expect(tab.devToolsController.views == nil)
        #expect(host.superview == nil)
    }
}

/// Docked DevTools needs the fork's embedded DevTools fix (API 4).
@Suite struct CEFDevToolsSupportTests {
    @Test func dockingNeedsForkAPI4() {
        #expect(!CEFDevToolsSupport.allowsEmbedded(forkAPIVersion: 2, bundleIdentifier: "com.cmuxterm.app", environment: [:]))
        #expect(!CEFDevToolsSupport.allowsEmbedded(forkAPIVersion: 3, bundleIdentifier: "com.cmuxterm.app", environment: [:]))
        #expect(CEFDevToolsSupport.allowsEmbedded(forkAPIVersion: 4, bundleIdentifier: "com.cmuxterm.app", environment: [:]))
    }

    @Test func developmentOverrideOnlyForDebugBundles() {
        let env = ["CMUX_NEXT_CEF_EMBEDDED_DEVTOOLS": "1"]
        #expect(CEFDevToolsSupport.allowsEmbedded(forkAPIVersion: 2, bundleIdentifier: "com.cmuxterm.app.debug.x", environment: env))
        #expect(!CEFDevToolsSupport.allowsEmbedded(forkAPIVersion: 2, bundleIdentifier: "com.cmuxterm.app", environment: env))
    }
}

/// Fork dock sides and the left dock.
@Suite struct CEFDevToolsDockSideTests {
    @Test func forkSidesMapToPaneDocks() {
        #expect(CEFDevToolsController.dock(forkSide: 0) == .window)
        #expect(CEFDevToolsController.dock(forkSide: 1) == .left)
        #expect(CEFDevToolsController.dock(forkSide: 2) == .bottom)
        #expect(CEFDevToolsController.dock(forkSide: 3) == .right)
        #expect(CEFDevToolsController.dock(forkSide: 9) == nil)
    }

    @Test func leftDockMirrorsRight() {
        var layout = CEFDevToolsLayout()
        layout.dock = .left
        layout.rightFraction = 0.4
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let frames = layout.frames(in: bounds, devToolsDocked: true)
        #expect(frames.devTools.minX == 0)
        #expect(frames.line.minX == frames.devTools.maxX)
        #expect(frames.page.minX == frames.line.maxX)
        #expect(frames.page.maxX == 1000)
        layout.dragDivider(to: CGPoint(x: 300, y: 10), in: bounds)
        #expect(abs(layout.frames(in: bounds, devToolsDocked: true).devTools.width - 300) <= 1)
    }
}
