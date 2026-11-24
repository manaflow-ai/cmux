import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// When an in-tree page's resize holds its window's Core Animation commit for the page's frame at the new size (fork API
/// 32 fence), as Chrome's own window does (`NativeWidgetNSWindowBridge::ShouldWaitInPreCommit`): only while the window
/// itself takes a new size, never for a resize inside the window (a divider drag, a pane spring) and never during a full
/// screen transition. The user's recordings (defects.md 5, 6, 8): every divider drag frame held the window for each page's
/// frame, so the window updated at about 28 of 60 frames a second, and the full screen transitions froze.
@MainActor
@Suite(.serialized, .closesItsWindows) struct CEFInTreeResizeFenceTests {
    final class Fork {
        private(set) var fences = 0
        private(set) var timeouts: [Int32] = []
        let page = NSView()
        var calls: CEFInTreeCalls {
            CEFInTreeCalls(setInTreeHosting: { [self] _, container in container == nil ? nil : page },
                           contentView: { [self] _ in page },
                           resizeFence: { [self] _, _, timeout, done in
                               fences += 1
                               timeouts.append(timeout)
                               done(true)
                               return true
                           })
        }
    }

    let fork = Fork()

    /// A borderless window off screen with an in-tree page in a host view.
    func makeInTree(_ make: (@escaping CEFLayerHosting.Scheduler, CEFResizeFences) -> CEFInTreeHosting)
        -> (CEFInTreeHosting, CEFHostView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.wantsLayer = true
        let host = CEFHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(host)
        let hosting = make({ $0() }, CEFResizeFences(makePort: { _ in
            var name = mach_port_t(MACH_PORT_NULL)
            guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &name) == KERN_SUCCESS,
                  mach_port_insert_right(mach_task_self_, name, name, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
                  == KERN_SUCCESS else { return nil }
            return name
        }))
        hosting.view = host
        #expect(hosting.pageWindowCreated(browser: 4, calls: fork.calls))
        #expect(hosting.isInTree)
        return (hosting, host, window)
    }

    func withInTreeOn(_ body: () throws -> Void) rethrows {
        InTreePages.shared.setForTesting(requested: true, engine: .supported)
        defer { InTreePages.shared.setForTesting(requested: nil) }
        try body()
    }

    /// A resize inside the window (a divider drag, a pane spring) waits for the page's frame at most half a display frame:
    /// a page that draws in time shows with its pane (other-Mac run on c76917cb: with no wait, 189 of 504 divider-drag
    /// frames showed the page a frame stale, against 10 of 503 with the wait), and a slow one shows its last frame instead
    /// of halving the window's rate (the user's heavy page with a wait longer than a frame: about 28 of 60 frames a second).
    @Test func aResizeInsideTheWindowWaitsAtMostHalfAFrame() throws {
        withInTreeOn {
            let (hosting, _, window) = makeInTree { CEFInTreeHosting(schedule: $0, resizeFences: $1) }
            defer { window.close() }
            // A divider drag frame: the page's view takes a new size, the window keeps its own.
            hosting.pageViewResized()
            hosting.pageViewResized()
            let refreshMs = (NSScreen.screens.map(\.minimumRefreshInterval).min() ?? 1.0 / 60) * 1_000
            #expect(fork.fences == 2, "a divider drag frame showed the pane without waiting for the page's frame")
            #expect(fork.timeouts.allSatisfy { Double($0) <= refreshMs * 0.5 }, "an in-window resize waited longer than half a frame: \(fork.timeouts)")
        }
    }

    @Test func aResizeOfTheWindowItselfHoldsItsCommitForThePagesFrame() {
        withInTreeOn {
            let (hosting, _, window) = makeInTree { CEFInTreeHosting(schedule: $0, resizeFences: $1) }
            defer { window.close() }
            hosting.pageViewResized()  // the first resize only learns the window's size (an in-window wait)
            window.setContentSize(NSSize(width: 520, height: 360))
            hosting.pageViewResized()
            let refreshMs = (NSScreen.screens.map(\.minimumRefreshInterval).min() ?? 1.0 / 60) * 1_000
            #expect(fork.fences == 2, "a window resize showed the window before the page's frame at its size")
            #expect(fork.timeouts.last.map { Double($0) >= max(8, refreshMs.rounded(.up)) } == true,
                    "a window resize waited less than a frame for the page: \(fork.timeouts)")
        }
    }

    @Test func aFullScreenTransitionNeverHoldsTheWindowsCommit() {
        #expect(CEFInTreeHosting.fenceTimeoutMs(windowResized: true, fullScreenTransition: true, refreshMs: 8.33) == nil)
        #expect(CEFInTreeHosting.fenceTimeoutMs(windowResized: false, fullScreenTransition: true, refreshMs: 8.33) == nil)
        #expect(CEFInTreeHosting.fenceTimeoutMs(windowResized: true, fullScreenTransition: false, refreshMs: 8.33) == 9)
        #expect(CEFInTreeHosting.fenceTimeoutMs(windowResized: true, fullScreenTransition: false, refreshMs: 16.67) == 17)
        #expect(CEFInTreeHosting.fenceTimeoutMs(windowResized: false, fullScreenTransition: false, refreshMs: 8.33) == 4)
        #expect(CEFInTreeHosting.fenceTimeoutMs(windowResized: false, fullScreenTransition: false, refreshMs: 16.67) == 8)
    }
}

/// An in-tree page needs no window page-update fan-out (``CEFHostView/pagesNeedUpdate(force:geometryOnly:)``): the fork's
/// update of it reads no occlusion or clip and already runs on the frame notices of its host and the host's ancestors.
/// Each post repeated that update (a headless window frame and a Views layout of the hidden Browser view) once more per
/// page per motion frame.
@MainActor
@Suite(.serialized, .closesItsWindows) struct CEFInTreeGeometryPostTests {
    @Test func anInTreePagesHostPostsNoGeometryOnTheWindowsPageUpdate() {
        InTreePages.shared.setForTesting(requested: true, engine: .supported)
        defer { InTreePages.shared.setForTesting(requested: nil) }
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = CEFHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(host)
        let page = NSView()
        let calls = CEFInTreeCalls(setInTreeHosting: { _, container in container == nil ? nil : page }, contentView: { _ in page })
        host.inTree.pageWindowCreated(browser: 5, calls: calls)
        CFRunLoopRunInMode(.defaultMode, 0.01, false)  // the request runs at the end of the turn
        #expect(host.inTree.isInTree)
        let posts = CEFHostView.trackerStats.geometryPosts
        host.frame.origin.x = 30  // a motion frame moved it
        host.pagesNeedUpdate(force: false, geometryOnly: true)
        host.pagesNeedUpdate(force: false)
        #expect(CEFHostView.trackerStats.geometryPosts == posts, "an in-tree page's host posted the fork a geometry change per page update")
    }
}
