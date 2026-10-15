import AppKit
import CmuxBrowser
import CmuxCEF
import Foundation
import Testing
@testable import CmuxCEFBrowser

/// Records the shim calls a page's features make.
@MainActor
private final class RecordingShim: CEFPageFeatureShim {
    enum Call: Equatable {
        case find(Int32, String, forward: Bool, findNext: Bool)
        case stopFinding(Int32, clear: Bool)
        case zoom(Int32, Double)
        case devTools(Int32, Int32, Int32, Int32)
        case placement(Int32, hasParent: Bool, CGRect)
        case focus(Int32, Bool)
        case menuDone(Int32, Int32)
    }

    var forkAPIVersion: Int32 = 13
    private(set) var calls: [Call] = []
    var onFind: (() -> Void)?

    func find(browser: Int32, text: String, forward: Bool, matchCase: Bool, findNext: Bool) {
        calls.append(.find(browser, text, forward: forward, findNext: findNext))
        onFind?()
    }
    func stopFinding(browser: Int32, clearSelection: Bool) { calls.append(.stopFinding(browser, clear: clearSelection)) }
    func setZoomLevel(browser: Int32, level: Double) { calls.append(.zoom(browser, level)) }
    func devToolsCommand(browser: Int32, command: Int32, x: Int32, y: Int32) { calls.append(.devTools(browser, command, x, y)) }
    func devToolsSetPlacement(browser: Int32, parentView: UnsafeMutableRawPointer?, frame: CGRect) {
        calls.append(.placement(browser, hasParent: parentView != nil, frame))
    }
    func devToolsSetFocus(browser: Int32, focused: Bool) { calls.append(.focus(browser, focused)) }
    func contextMenuDone(token: Int32, commandID: Int32) { calls.append(.menuDone(token, commandID)) }
}

@MainActor
@Suite struct CEFPageFeaturesTests {
    private func makeFeatures(shim: RecordingShim) -> (CEFPageFeatures, NSWindow, UserDefaults) {
        let defaults = UserDefaults(suiteName: "CEFPageFeaturesTests.\(UUID().uuidString)")!
        let features = CEFPageFeatures(
            shim: shim, browserID: { 7 }, pageView: CEFHostView(),
            layoutStore: BrowserDevToolsLayoutStore(defaults: defaults)
        )
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 801, height: 601), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = features.paneView
        return (features, window, defaults)
    }

    @Test func findResultsAnswerTheFindBarForThisBrowserOnly() async {
        let shim = RecordingShim()
        let (features, _, _) = makeFeatures(shim: shim)
        shim.onFind = {
            features.handle(.findResult(browser: 8, count: 9, activeOrdinal: 9, isFinal: true))
            features.handle(.findResult(browser: 7, count: 3, activeOrdinal: 2, isFinal: true))
        }
        let count = await features.nativeFind.search(needle: "cmux")
        #expect(count == BrowserFindMatchCount(total: 3, selected: 1))
        #expect(shim.calls == [.find(7, "cmux", forward: true, findNext: false)])
    }

    @Test func devToolsCommandsMapToShimCommandsAndDockInThePane() {
        let shim = RecordingShim()
        let (features, _, _) = makeFeatures(shim: shim)
        features.devTools.perform(.show)
        features.devTools.perform(.console)
        features.devTools.perform(.inspect(x: 10, y: 20))
        #expect(shim.calls == [
            .devTools(7, CEFShimLibrary.DevToolsCommand.show.rawValue, 0, 0),
            .devTools(7, CEFShimLibrary.DevToolsCommand.console.rawValue, 0, 0),
            .devTools(7, CEFShimLibrary.DevToolsCommand.inspectAt.rawValue, 10, 20),
        ])
        #expect(features.handle(.devToolsWillOpen(browser: 7)))
        guard case .placement(7, true, let frame) = shim.calls.last else {
            Issue.record("expected a docked placement, got \(String(describing: shim.calls.last))")
            return
        }
        #expect(frame.origin == .zero && frame.width == 801)
        #expect(features.handle(.devToolsOpened(browser: 7, devTools: 99, docked: true)))
        #expect(features.devTools.state == BrowserDevToolsState(isOpen: true, dock: .bottom))
        // First report: the frontend's saved side, ignored; then a real choice moves the tools.
        #expect(features.handle(.tab(.devToolsDockSide, browser: 7, window: 1, value: 3)))
        #expect(features.devTools.state.dock == .bottom)
        #expect(features.handle(.tab(.devToolsDockSide, browser: 7, window: 1, value: 3)))
        #expect(features.devTools.state.dock == .right)
        features.devTools.perform(.toggle)
        #expect(shim.calls.last == .devTools(7, CEFShimLibrary.DevToolsCommand.close.rawValue, 0, 0))
        #expect(features.handle(.devToolsClosed(browser: 7, devTools: 99)))
        #expect(!features.devTools.state.isOpen)
    }

    @Test func oldForksOpenDevToolsInChromiumsOwnWindow() {
        let shim = RecordingShim()
        shim.forkAPIVersion = 3
        let (features, _, _) = makeFeatures(shim: shim)
        features.handle(.devToolsWillOpen(browser: 7))
        guard case .placement(7, false, _) = shim.calls.last else {
            Issue.record("expected an own-window placement")
            return
        }
    }

    @Test func otherBrowsersEventsAreIgnored() {
        let shim = RecordingShim()
        let (features, _, _) = makeFeatures(shim: shim)
        #expect(!features.handle(.devToolsWillOpen(browser: 8)))
        #expect(!features.handle(.title(browser: 7, title: "x")))
        #expect(shim.calls.isEmpty)
    }

    @Test func dividerAndChromeRectsBecomeHolesInBothWindows() throws {
        let shim = RecordingShim()
        let (features, _, _) = makeFeatures(shim: shim)
        let page = try #require(features.paneView.pageView as? CEFHostView)
        features.chromeOcclusionRects = [CGRect(x: 600, y: 560, width: 190, height: 36)]
        #expect(page.occlusionRects == [CGRect(x: 600, y: 560, width: 190, height: 36)])
        features.handle(.devToolsWillOpen(browser: 7))
        features.handle(.devToolsOpened(browser: 7, devTools: 99, docked: true))
        features.paneView.layoutSubtreeIfNeeded()
        // 601 high: DevTools 240, line at 240, page from 241; grab = line +/- 3.
        #expect(page.frame == CGRect(x: 0, y: 241, width: 801, height: 360))
        #expect(page.occlusionRects == [
            CGRect(x: 600, y: 319, width: 190, height: 36),
            CGRect(x: 0, y: 0, width: 801, height: 3),
        ])
        let devToolsHost = try #require(features.devTools.devToolsHostView as? CEFHostView)
        #expect(devToolsHost.occlusionRects == [CGRect(x: 0, y: 237, width: 801, height: 3)])
        // Right-docked DevTools sit under the find card at the top right: it is a hole there too.
        features.devTools.perform(.dock(.right))
        features.paneView.layoutSubtreeIfNeeded()
        // 801 wide: DevTools 360 (0.45 of 800) at x 441, line at 440.
        #expect(devToolsHost.frame == CGRect(x: 441, y: 0, width: 360, height: 601))
        #expect(devToolsHost.occlusionRects.contains(CGRect(x: 159, y: 560, width: 190, height: 36)))
    }

    @Test func noEventsOrCallsBeforeChromiumCreatesThePage() async {
        let shim = RecordingShim()
        let features = CEFPageFeatures(
            shim: shim, browserID: { nil }, pageView: CEFHostView(),
            layoutStore: BrowserDevToolsLayoutStore(defaults: UserDefaults(suiteName: "CEFPageFeaturesTests.\(UUID().uuidString)")!)
        )
        #expect(await features.nativeFind.search(needle: "x") == nil)
        features.devTools.perform(.show)
        #expect(!features.handle(.devToolsWillOpen(browser: 7)))
        #expect(shim.calls.isEmpty)
    }

    @Test func contextMenuInABackgroundPageIsDismissedAtOnce() {
        let shim = RecordingShim()
        let features = CEFPageFeatures(
            shim: shim, browserID: { 7 }, pageView: CEFHostView(),
            layoutStore: BrowserDevToolsLayoutStore(defaults: UserDefaults(suiteName: "CEFPageFeaturesTests.\(UUID().uuidString)")!)
        )
        #expect(features.handle(.contextMenu(browser: 7, token: 42, x: 1, y: 2, itemsJSON: "[]", paramsJSON: "{}")))
        #expect(shim.calls == [.menuDone(42, -1)])
    }
}
