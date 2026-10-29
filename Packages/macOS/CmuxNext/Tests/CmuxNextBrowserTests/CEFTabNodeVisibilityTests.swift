import AppKit
@testable import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import Testing

/// A Chromium tab follows its visibility tree node through the fork's
/// `cmux_shim_tab_set_visibility` (fork API 37), as Chrome's tab strip hides a background WebContents
/// (`WebContentsImpl::UpdateWebContentsVisibility`): the node's hide, show and occlusion reach Chromium in the
/// node's own turn, a capture keeps a hidden tab painting, and the freeze is the second step after the hide.
/// Below API 37 nothing is sent and the freeze works as before. Against a spy shim that records the calls in order.
@MainActor @Suite(.serialized) struct CEFTabNodeVisibilityTests {
    @Test func belowForkAPI37TheTabFollowsNoNodeAndFreezesAsBefore() throws {
        let rig = try VisibilityRig(forkAPI: CEFForkFeatures.tabVisibilityForkAPI - 1)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let node = VisibilityNode(root: "tab", own: .visible)
        #expect(!tab.followVisibility(of: node, capture: BrowserPageCapture.votes(on:)))
        node.set(.hidden)
        #expect(VisibilitySpy.calls.isEmpty, "a fork without the call hears nothing")
        #expect(tab.setFrozen(true))
        #expect(VisibilitySpy.calls == ["freeze 7 1"])
    }

    @Test func theExportIsOptional() throws {
        VisibilitySpy.reset(forkAPI: CEFForkFeatures.tabVisibilityForkAPI, exportsVisibility: false)
        let library = try VisibilitySpy.library()
        #expect(library.tabSetVisibility == nil)
        #expect(!CEFForkFeatures(library).tabVisibility, "an API 37 fork with an older shim keeps today's behavior")
    }

    /// Selecting the tab shows it to Chromium in the selection's turn; a hide hides it in the hide's turn, one call each.
    @Test func hideAndShowReachChromiumInTheNodesTurn() throws {
        let rig = try VisibilityRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let window = VisibilityNode(root: "window", own: .visible)
        let node = VisibilityNode("tab", own: .hidden, parent: window)
        #expect(tab.followVisibility(of: node, capture: BrowserPageCapture.votes(on:)))
        #expect(VisibilitySpy.calls == ["visibility 7 3 0"], "the follow tells Chromium the node's state at once")

        node.set(.visible)
        #expect(VisibilitySpy.calls.last == "visibility 7 1 0")
        node.set(.hidden)
        #expect(VisibilitySpy.calls.last == "visibility 7 3 0")
        #expect(VisibilitySpy.calls.count == 3)
    }

    /// An occluded window gives OCCLUDED; the window coming back gives VISIBLE.
    @Test func anOccludedWindowGivesOccluded() throws {
        let rig = try VisibilityRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let window = VisibilityNode(root: "window", own: .visible)
        let node = VisibilityNode("tab", own: .visible, parent: window)
        tab.followVisibility(of: node, capture: BrowserPageCapture.votes(on:))
        window.set(.occluded)
        window.set(.visible)
        #expect(VisibilitySpy.calls == ["visibility 7 1 0", "visibility 7 2 0", "visibility 7 1 0"])
    }

    /// The shown tab of a window that is minimized is hidden to Chromium in the window node's own
    /// turn, with no delay and no DevTools session (the lifecycle call the fork needed before API 37, since
    /// `WasHidden` does nothing for a windowed browser); deminiaturized, it is shown again.
    @Test func aMinimizedWindowHidesItsShownTabAtOnce() throws {
        let rig = try VisibilityRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let window = VisibilityNode(root: "window", own: .visible)
        let node = VisibilityNode("tab", own: .visible, parent: window)
        tab.followVisibility(of: node, capture: BrowserPageCapture.votes(on:))
        window.set(.hidden)
        #expect(VisibilitySpy.calls == ["visibility 7 1 0", "visibility 7 3 0"])
        window.set(.visible)
        #expect(VisibilitySpy.calls == ["visibility 7 1 0", "visibility 7 3 0", "visibility 7 1 0"])
    }

    /// `offScreenWindowPageFreeze`: below API 37 the shown page of an off-screen window follows no node,
    /// so Chromium still counts it visible; it is hidden and frozen through DevTools, and the thaw goes out at once, so
    /// an agent call after it reaches a live page. A second freeze sends nothing.
    @Test func belowForkAPI37AShownPageInAnOffScreenWindowIsHiddenThenFrozen() throws {
        let rig = try VisibilityRig(forkAPI: CEFForkFeatures.tabVisibilityForkAPI - 1)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        #expect(tab.freezeShownInOffScreenWindow())
        #expect(VisibilitySpy.calls == ["devtools 7 Page.setWebLifecycleState"])
        #expect(tab.nodeVisibility.isPageFrozen)
        #expect(tab.freezeShownInOffScreenWindow())
        #expect(VisibilitySpy.calls.count == 1, "a frozen page was frozen again: \(VisibilitySpy.calls)")
        #expect(tab.setFrozen(false))
        #expect(VisibilitySpy.calls == ["devtools 7 Page.setWebLifecycleState", "freeze 7 0"])
        #expect(!tab.nodeVisibility.isPageFrozen)
    }

    /// From API 37 the window node hid the tab: its off-screen freeze is the hidden page's, with no DevTools session.
    @Test func aTabThatFollowsItsNodeFreezesItsOffScreenPageAsAHiddenOne() throws {
        let rig = try VisibilityRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let window = VisibilityNode(root: "window", own: .visible)
        let node = VisibilityNode("tab", own: .visible, parent: window)
        tab.followVisibility(of: node, capture: BrowserPageCapture.votes(on:))
        #expect(!tab.freezeShownInOffScreenWindow(), "a page Chromium counts visible was frozen")
        window.set(.hidden)
        #expect(tab.freezeShownInOffScreenWindow())
        #expect(VisibilitySpy.calls == ["visibility 7 1 0", "visibility 7 3 0", "freeze 7 1"])
    }

    /// A capture vote that does not stay hidden keeps a hidden tab painting (Chrome's visible capturer); its release
    /// gives the hidden page back. A captured page is not frozen.
    @Test func aCaptureVoteKeepsAHiddenTabPaintingAndAwake() throws {
        let rig = try VisibilityRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let node = VisibilityNode(root: "tab", own: .hidden)
        tab.followVisibility(of: node, capture: BrowserPageCapture.votes(on:))
        let capture = node.captureVote(reason: "test capture", stayHidden: true)
        #expect(VisibilitySpy.calls.last == "visibility 7 3 2")
        #expect(!tab.setFrozen(true), "a captured page stays awake")
        capture.release()
        #expect(VisibilitySpy.calls.last == "visibility 7 3 0")
        #expect(tab.setFrozen(true))
        #expect(VisibilitySpy.calls == ["visibility 7 3 0", "visibility 7 3 2", "visibility 7 3 0", "freeze 7 1"])
    }

    /// A capture of a hidden tab that is already frozen thaws it first, while Chromium still counts it hidden, then
    /// paints it, as Chrome's freezing policy unfreezes a captured page (freezing_policy.cc `CannotFreezeReason`). The
    /// hibernation's own thaw after it sends nothing, and the page freezes again once the capture ends.
    @Test func aCaptureOfAFrozenHiddenTabThawsItBeforeItPaints() throws {
        let rig = try VisibilityRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let node = VisibilityNode(root: "tab", own: .hidden)
        tab.followVisibility(of: node, capture: BrowserPageCapture.votes(on:))
        #expect(tab.setFrozen(true))
        let capture = node.captureVote(reason: "test capture", stayHidden: true)
        #expect(VisibilitySpy.calls == ["visibility 7 3 0", "freeze 7 1", "freeze 7 0", "visibility 7 3 2"])
        #expect(tab.setFrozen(false), "a thaw of a page that is not frozen succeeds")
        #expect(VisibilitySpy.calls.count == 4, "and sends nothing")
        #expect(!tab.setFrozen(true), "a captured page stays awake")
        capture.release()
        #expect(tab.setFrozen(true))
        #expect(Array(VisibilitySpy.calls.dropFirst(4)) == ["visibility 7 3 0", "freeze 7 1"])
    }

    /// The capture source decides the mode: a vote that stays hidden paints the page and keeps it hidden to script.
    @Test func aStayHiddenCaptureSendsHiddenButPainting() throws {
        let rig = try VisibilityRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let node = VisibilityNode(root: "tab", own: .hidden)
        tab.followVisibility(of: node) { _ in .hiddenButPainting }
        #expect(VisibilitySpy.calls == ["visibility 7 3 1"])
        #expect(!tab.setFrozen(true))
    }

    /// The freeze is the second step: a tab whose node is visible is never frozen; after the hide it is.
    @Test func theFreezeFollowsTheHide() throws {
        let rig = try VisibilityRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let node = VisibilityNode(root: "tab", own: .visible)
        tab.followVisibility(of: node, capture: BrowserPageCapture.votes(on:))
        #expect(!tab.setFrozen(true), "Chromium never freezes a visible page")
        node.set(.hidden)
        #expect(tab.setFrozen(true))
        #expect(VisibilitySpy.calls == ["visibility 7 1 0", "visibility 7 3 0", "freeze 7 1"])
    }

    /// A frozen tab shown again thaws while Chromium still counts it hidden, then shows.
    @Test func aShowThawsBeforeItShows() throws {
        let rig = try VisibilityRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let node = VisibilityNode(root: "tab", own: .hidden)
        tab.followVisibility(of: node, capture: BrowserPageCapture.votes(on:))
        #expect(tab.setFrozen(true))
        node.set(.visible)
        #expect(VisibilitySpy.calls == ["visibility 7 3 0", "freeze 7 1", "freeze 7 0", "visibility 7 1 0"])
        node.set(.hidden)
        node.set(.visible)
        #expect(Array(VisibilitySpy.calls.dropFirst(4)) == ["visibility 7 3 0", "visibility 7 1 0"], "a thawed page is not thawed again")
    }

    /// A tab that follows its node before its browser exists tells the browser when it attaches, before it paints.
    @Test func aNewBrowserHearsTheNodeWhenItAttaches() throws {
        let rig = try VisibilityRig()
        defer { rig.close() }
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: rig.runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: rig.runtime)
        let node = VisibilityNode(root: "tab", own: .hidden)
        #expect(tab.followVisibility(of: node, capture: BrowserPageCapture.votes(on:)))
        #expect(VisibilitySpy.calls.isEmpty)
        try rig.attach(tab, host: host)
        #expect(VisibilitySpy.calls == ["visibility 7 3 0"])
    }

    /// The spare's never-shown placeholder: hidden to Chromium and frozen through the fork, with no DevTools session;
    /// below API 37 through DevTools as before.
    @Test func aNeverShownPageIsHiddenThenFrozenWithoutDevTools() throws {
        let rig = try VisibilityRig()
        defer { rig.close() }
        CEFTabNodeVisibility.freezeNeverShown(9, runtime: rig.runtime)
        #expect(VisibilitySpy.calls == ["visibility 9 3 0", "freeze 9 1"])

        let older = try VisibilityRig(forkAPI: CEFForkFeatures.tabVisibilityForkAPI - 1)
        defer { older.close() }
        CEFTabNodeVisibility.freezeNeverShown(9, runtime: older.runtime)
        #expect(VisibilitySpy.calls == ["devtools 9 Page.setWebLifecycleState"])
    }

    @Test func aClosedTabSendsNothing() throws {
        let rig = try VisibilityRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let node = VisibilityNode(root: "tab", own: .visible)
        tab.followVisibility(of: node, capture: BrowserPageCapture.votes(on:))
        tab.close()
        VisibilitySpy.calls = []
        node.set(.hidden)
        #expect(VisibilitySpy.calls.isEmpty)
    }

    // MARK: Rig

    @MainActor final class VisibilityRig {
        let runtime: CEFRuntime
        let root: URL

        init(forkAPI: Int32 = CEFForkFeatures.tabVisibilityForkAPI) throws {
            VisibilitySpy.reset(forkAPI: forkAPI, exportsVisibility: true)
            root = FileManager.default.temporaryDirectory.appending(path: "cef-tab-visibility-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try VisibilitySpy.library(), storage: CEFProfileStorage(root: root))
        }

        /// A tab whose browser 7 exists (AFTER_CREATED); the calls recorded so far are dropped.
        func attachedTab() throws -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            try attach(tab, host: host)
            VisibilitySpy.calls = []
            return tab
        }

        func attach(_ tab: CEFTab, host: CEFPaneHost) throws {
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
            try #require(tab.browserID == 7)
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// The shim's visibility, freeze and lifecycle DevTools calls, in order; every other function does nothing.
private nonisolated enum VisibilitySpy {
    nonisolated(unsafe) static var forkAPI: Int32 = 37
    nonisolated(unsafe) static var exportsVisibility = true
    nonisolated(unsafe) static var calls: [String] = []

    static func reset(forkAPI api: Int32, exportsVisibility exports: Bool) {
        forkAPI = api
        exportsVisibility = exports
        calls = []
    }

    static func library() throws -> CEFShimLibrary {
        try CEFShimLibrary.resolving(symbol)
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let version: @convention(c) () -> Int32 = { VisibilitySpy.forkAPI }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let visibility: @convention(c) (Int32, Int32, Int32) -> Int32 = { browser, value, capture in
            VisibilitySpy.calls.append("visibility \(browser) \(value) \(capture)")
            return 1
        }
        let freeze: @convention(c) (Int32, Int32) -> Int32 = { browser, frozen in
            VisibilitySpy.calls.append("freeze \(browser) \(frozen)")
            return 1
        }
        let devToolsCall: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { browser, method, _ in
            let method = method.map { String(cString: $0) } ?? ""
            if method == "Page.setWebLifecycleState" { VisibilitySpy.calls.append("devtools \(browser) \(method)") }
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        if name == "cmux_shim_tab_set_visibility" {
            return exportsVisibility ? unsafeBitCast(visibility, to: UnsafeMutableRawPointer.self) : nil
        }
        return switch name {
        case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_tab_set_frozen": unsafeBitCast(freeze, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_devtools_call": unsafeBitCast(devToolsCall, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
