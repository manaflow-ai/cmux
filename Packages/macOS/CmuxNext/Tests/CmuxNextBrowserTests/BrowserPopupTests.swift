import AppKit
import Testing
@testable import CmuxNextBrowser

/// Sized popups (`window.open` with window features, OAuth sign-in,
/// `chrome.windows.create({type: 'popup'})`) open in a floating panel with
/// their own Chromium window, never as a tab of the opener's pane and never
/// in the opener's Chromium window (which shows one tab at a time).
@MainActor
@Suite struct BrowserPopupTests {
    private final class Recorder: BrowserTabDelegate {
        var popups: [(any BrowserTab, BrowserPopupRequest)] = []
        var adopted: [(any BrowserTab, BrowserNewTabDisposition)] = []
        var escapes = 0
        func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
            switch intent {
            case .openPopup(let child, let request): popups.append((child, request))
            case .adoptTab(let child, let disposition): adopted.append((child, disposition))
            case .unhandledEscape: escapes += 1
            default: break
            }
        }
    }

    private func makeOpener(machineKey: String? = nil) -> CEFTab {
        let runtime = CEFRuntime.shared
        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default, machineKey: machineKey)
        let host = runtime.host(for: key)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        return tab
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func cleanUp(_ browsers: [Int32]) {
        for browser in browsers { CEFRuntime.shared.tabsByBrowser[browser] = nil }
    }

    /// OAuth: `window.open(url, 'auth', 'width=480,height=640')` reaches the
    /// host as a popup with the size the page asked for.
    @Test func aSizedPopupOpensAsAPopupWithItsSize() {
        let opener = makeOpener()
        let recorder = Recorder()
        opener.delegate = recorder
        defer { cleanUp([71_001]) }
        opener.host.adoptChromiumTab(browser: 71_001, disposition: .popup, bounds: CGRect(x: 30, y: 40, width: 480, height: 640))
        #expect(recorder.adopted.isEmpty)
        #expect(recorder.popups.count == 1)
        #expect(recorder.popups.first?.1 == BrowserPopupRequest(size: CGSize(width: 480, height: 640), origin: CGPoint(x: 30, y: 40)))
    }

    /// `chrome.windows.create({type: 'popup'})` without a size is still a
    /// popup; plain links stay tabs.
    @Test func popupWithoutASizeIsStillAPopupAndLinksStayTabs() {
        let opener = makeOpener()
        let recorder = Recorder()
        opener.delegate = recorder
        defer { cleanUp([71_002, 71_003]) }
        opener.host.adoptChromiumTab(browser: 71_002, disposition: .popup)
        opener.host.adoptChromiumTab(browser: 71_003, disposition: .foregroundTab)
        #expect(recorder.popups.map(\.1) == [BrowserPopupRequest()])
        #expect(recorder.adopted.map(\.1) == [.foregroundTab])
    }

    /// The popup gets a Chromium window of its own (same profile and store,
    /// so a remote machine's localhost page keeps its proxy), not a tab of
    /// the opener's window.
    @Test func aPopupHasItsOwnWindowHostInTheOpenersStore() throws {
        let opener = makeOpener(machineKey: "ab12")
        let recorder = Recorder()
        opener.delegate = recorder
        defer { cleanUp([71_004]) }
        opener.host.adoptChromiumTab(browser: 71_004, disposition: .popup, bounds: CGRect(x: 0, y: 0, width: 300, height: 200))
        let popup = try #require(recorder.popups.first?.0 as? CEFTab)
        #expect(popup.host !== opener.host)
        #expect(popup.host.key.profile == opener.host.key.profile)
        #expect(popup.host.key.machineKey == "ab12")
        #expect(popup.host.tabs.contains { $0 === popup })
        #expect(!opener.host.tabs.contains { $0 === popup })
    }

    /// Showing the popup in its panel must leave the opener's page where it
    /// is: a Chromium window shows one tab, so sharing the opener's window
    /// would blank the opener's pane.
    @Test func showingAPopupLeavesTheOpenersPageInItsPane() throws {
        let opener = makeOpener()
        let recorder = Recorder()
        opener.delegate = recorder
        defer { cleanUp([71_005]) }
        let paneWindow = makeWindow()
        paneWindow.contentView?.addSubview(opener.contentView)
        #expect(opener.host.hostView.superview === opener.contentView)
        opener.host.adoptChromiumTab(browser: 71_005, disposition: .popup, bounds: CGRect(x: 0, y: 0, width: 300, height: 200))
        let popup = try #require(recorder.popups.first?.0 as? CEFTab)
        let panelWindow = makeWindow()
        panelWindow.contentView?.addSubview(popup.contentView)
        #expect(opener.host.hostView.superview === opener.contentView)
        #expect(opener.host.visibleTab === opener)
        #expect(popup.host.visibleTab === popup)
    }

    /// Escape that the page did not use reaches the host (the panel closes
    /// on it); the shim reports it after the renderer passed on the key.
    @Test func anUnhandledEscapeReachesTheHost() {
        let opener = makeOpener()
        let recorder = Recorder()
        opener.delegate = recorder
        CEFRuntime.shared.register(opener, browser: 71_006)
        defer { cleanUp([71_006]) }
        CEFRuntime.shared.handle(CEFShimEvent(kind: 28, browser: 71_006, request: 0, a: 0x1B, b: 0, s1: "", s2: ""))
        #expect(recorder.escapes == 1)
    }

    /// A window request's bounds stay with the placement until the tab
    /// arrives in that window.
    @Test func placementsKeepTheRequestedBounds() {
        var queue = CEFPlacementQueue()
        let bounds = CGRect(x: 1, y: 2, width: 480, height: 640)
        queue.record(window: 5, CEFPlacement(disposition: .popup, bounds: bounds))
        queue.record(window: 5, CEFPlacement(disposition: .foregroundTab, bounds: nil))
        #expect(queue.take(window: 5) == CEFPlacement(disposition: .popup, bounds: bounds))
        #expect(queue.take(window: 5) == CEFPlacement(disposition: .foregroundTab, bounds: nil))
        #expect(queue.take(window: 5) == nil)
    }

    /// A placement recorded for a tab duplicate the fork refused is withdrawn,
    /// so the next tab Chromium adds to that window keeps its own placement.
    @Test func withdrawnPlacementLeavesOlderOnes() {
        var queue = CEFPlacementQueue()
        queue.record(window: 5, CEFPlacement(disposition: .popup))
        queue.record(window: 5, CEFPlacement(disposition: .backgroundTab))
        queue.withdrawLast(window: 5)
        queue.withdrawLast(window: 6)
        #expect(queue.take(window: 5) == CEFPlacement(disposition: .popup))
        #expect(queue.take(window: 5) == nil)
    }

    @Test func requestFromFeatures() {
        #expect(BrowserPopupRequest(features: nil) == BrowserPopupRequest())
        #expect(BrowserPopupRequest(features: CGRect(x: 0, y: 0, width: 480, height: 0))
            == BrowserPopupRequest(size: CGSize(width: 480, height: 0)))
        #expect(BrowserPopupRequest(features: CGRect(x: 10, y: 0, width: 0, height: 0)).origin == CGPoint(x: 10, y: 0))
    }
}
