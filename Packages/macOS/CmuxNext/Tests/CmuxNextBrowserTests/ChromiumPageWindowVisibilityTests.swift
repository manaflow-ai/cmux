import AppKit
@testable import CmuxNextBrowser
import ObjectiveC
import Testing

/// https://github.com/manaflow-ai/cmux/issues/45785: a chat's content vanished while it loaded or its agent
/// worked, and the window's glass showed through. A hosted page's input window (`CefNSWindow`, a child window of
/// the cmux window) flipped to occluded on its own while the cmux window stayed visible (516 of 528 sub-second page
/// hides in a NIGHTLY's flicker ring). Chromium reads that window's own `isOnActiveSpace` and `occlusionState` on
/// the flip (`NativeWidgetNSWindowBridge::OnSpaceActivationMayHaveChanged`) and set the page's compositor invisible,
/// which dropped its pixels until a busy renderer drew again.
///
/// The stand-in page window answers what AppKit answered for the occluded child (`own*`) and carries the fork's
/// embedded flag; the stand-in parent is the cmux window, visible on the active Space unless a test says otherwise.
@MainActor @Suite struct ChromiumPageWindowVisibilityTests {
    class StandInPageWindow: NSWindow {
        var embedded = true
        var ownOcclusion: NSWindow.OcclusionState = []
        var ownActiveSpace = false
        weak var standInParent: NSWindow?
        @objc dynamic func isEmbeddedInParentView() -> Bool { embedded }
        @objc dynamic func containsWebContentsViewCocoa() -> Bool { true }
        override var occlusionState: NSWindow.OcclusionState { ownOcclusion }
        override var isOnActiveSpace: Bool { ownActiveSpace }
        override var parent: NSWindow? {
            get { standInParent }
            set { standInParent = newValue }
        }
    }

    class StandInParentWindow: NSWindow {
        var state: NSWindow.OcclusionState = .visible
        var activeSpace = true
        var children: [NSWindow] = []
        /// How many times the Space was asked: AppKit's `isOnActiveSpace` is a synchronous window-server round trip
        /// (`SLSWindowServerClientCopySpacesForWindows`).
        var spaceQueries = 0
        override var occlusionState: NSWindow.OcclusionState { state }
        override var isOnActiveSpace: Bool {
            spaceQueries += 1
            return activeSpace
        }
        override var childWindows: [NSWindow]? { children }
    }

    private static func pageWindowClass() throws -> StandInPageWindow.Type {
        let name = "CmuxTestVisibilityCefNSWindow_\(UInt32.random(in: 0 ... .max))"
        let cls = try #require(objc_allocateClassPair(StandInPageWindow.self, name, 0))
        objc_registerClassPair(cls)
        return try #require(cls as? StandInPageWindow.Type)
    }

    private static let frame = CGRect(x: 0, y: 0, width: 200, height: 100)

    private static func window(of type: StandInPageWindow.Type) throws -> StandInPageWindow {
        let windowType: NSWindow.Type = type
        let window = try #require(windowType.init(contentRect: frame, styleMask: [.borderless], backing: .buffered,
                                                  defer: true) as? StandInPageWindow)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func parent(of page: StandInPageWindow) -> StandInParentWindow {
        let parent = StandInParentWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
        parent.isReleasedWhenClosed = false
        parent.children = [page]
        page.standInParent = parent
        return parent
    }

    @Test func anEmbeddedPageStaysOnScreenWhileOnlyItsOwnWindowIsOccluded() throws {
        let cls = try Self.pageWindowClass()
        #expect(ChromiumPageWindowMain.installPageRules(on: cls))
        let page = try Self.window(of: cls)
        let parent = Self.parent(of: page)
        // What Chromium reads on the child's own flip: before, occluded and off the active Space.
        #expect(page.occlusionState.contains(.visible))
        #expect(page.isOnActiveSpace)
        // The cmux window really leaves the screen (minimized, another Space): the page goes too.
        parent.state = []
        parent.activeSpace = false
        #expect(!page.occlusionState.contains(.visible))
        #expect(!page.isOnActiveSpace)
    }

    @Test func aPageWindowThatIsNotEmbeddedOrHasNoParentKeepsItsOwnAnswer() throws {
        let cls = try Self.pageWindowClass()
        ChromiumPageWindowMain.installPageRules(on: cls)
        let page = try Self.window(of: cls)
        // Not a child window yet (a page before it shows, a detached page).
        #expect(!page.occlusionState.contains(.visible))
        #expect(!page.isOnActiveSpace)
        let parent = Self.parent(of: page)
        page.embedded = false
        #expect(!page.occlusionState.contains(.visible))
        #expect(!page.isOnActiveSpace)
        page.embedded = true
        #expect(page.occlusionState.contains(.visible))
        withExtendedLifetime(parent) {}
    }

    @Test func installingAgainIsHarmless() throws {
        let cls = try Self.pageWindowClass()
        #expect(ChromiumPageWindowVisibility.followParentWindow(cls))
        #expect(ChromiumPageWindowVisibility.followParentWindow(cls))
        let page = try Self.window(of: cls)
        let parent = Self.parent(of: page)
        #expect(page.isOnActiveSpace)
        parent.activeSpace = false
        #expect(!page.isOnActiveSpace)
    }

    /// Chromium reads a page window's `isOnActiveSpace` on each visibility change of the page
    /// (`NativeWidgetNSWindowBridge::OnVisibilityChanged`, `OnSpaceActivationMayHaveChanged`), and a pane's layout
    /// shows and hides a page (the New Tab spare, `NewTabSparePool.paneLayoutDidChange`) during a divider drag: each
    /// read asked the window server for the cmux window's Spaces, a synchronous round trip on the main thread
    /// (31 ms of the resize agent's sampled in-tree divider drags, bp-on-1). A visible window is on a visible Space,
    /// so a visible cmux window answers from its occlusion state, which AppKit keeps from the window server's own
    /// notices; only a cmux window out of sight is asked.
    @Test func aVisibleCmuxWindowAnswersItsPagesSpaceWithoutAskingTheWindowServer() throws {
        let cls = try Self.pageWindowClass()
        #expect(ChromiumPageWindowVisibility.followParentWindow(cls, spaceFromOcclusion: true))
        let page = try Self.window(of: cls)
        let parent = Self.parent(of: page)
        for _ in 0 ..< 3 { #expect(page.isOnActiveSpace) }
        #expect(parent.spaceQueries == 0)
        // Out of sight (covered, minimized, on another Space): the window server answers.
        parent.state = []
        #expect(page.isOnActiveSpace)
        #expect(parent.spaceQueries == 1)
        parent.activeSpace = false
        #expect(!page.isOnActiveSpace)
        #expect(parent.spaceQueries == 2)
        // Back in sight: no question again.
        parent.state = .visible
        #expect(page.isOnActiveSpace)
        #expect(parent.spaceQueries == 2)
    }

    /// The knob off (the measurement's baseline arm): every read asks the cmux window, as before.
    @Test func withoutTheKnobEveryReadAsksTheCmuxWindow() throws {
        let cls = try Self.pageWindowClass()
        #expect(ChromiumPageWindowVisibility.followParentWindow(cls, spaceFromOcclusion: false))
        let page = try Self.window(of: cls)
        let parent = Self.parent(of: page)
        #expect(page.isOnActiveSpace)
        #expect(page.isOnActiveSpace)
        #expect(parent.spaceQueries == 2)
    }

    @Test func otherWindowsKeepTheirAnswer() throws {
        ChromiumPageWindowMain.installPageRules(on: try Self.pageWindowClass())
        let page = try Self.window(of: StandInPageWindow.self)
        let parent = Self.parent(of: page)
        #expect(!page.isOnActiveSpace)
        withExtendedLifetime(parent) {}
    }

    /// Chromium reads a window's state only on that window's own notification: the cmux window's flip is passed on
    /// to its embedded page windows, and a page window's own flip to nothing else.
    @Test func theParentsFlipReachesItsEmbeddedPageWindowsOnly() throws {
        let cls = try Self.pageWindowClass()
        ChromiumPageWindowMain.installPageRules(on: cls)
        let page = try Self.window(of: cls)
        let other = try Self.window(of: cls)
        other.embedded = false
        let parent = Self.parent(of: page)
        parent.children.append(other)
        var notified: [ObjectIdentifier] = []
        ChromiumPageWindowVisibility.parentOcclusionChanged(parent) { notified.append(ObjectIdentifier($0)) }
        #expect(notified == [ObjectIdentifier(page)])
        notified.removeAll()
        ChromiumPageWindowVisibility.parentOcclusionChanged(page) { notified.append(ObjectIdentifier($0)) }
        #expect(notified.isEmpty)
    }
}
