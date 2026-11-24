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
        let page = NSView()
        var calls: CEFInTreeCalls {
            CEFInTreeCalls(setInTreeHosting: { [self] _, container in container == nil ? nil : page },
                           contentView: { [self] _ in page },
                           resizeFence: { [self] _, _, _, done in
                               fences += 1
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

    @Test func aResizeInsideTheWindowHoldsNoWindowCommit() {
        withInTreeOn {
            let (hosting, _, window) = makeInTree { CEFInTreeHosting(schedule: $0, resizeFences: $1) }
            defer { window.close() }
            // A divider drag frame: the page's view takes a new size, the window keeps its own.
            hosting.pageViewResized()
            #expect(fork.fences == 0, "a resize inside the window held the window's commit for the page's frame")
        }
    }
}
