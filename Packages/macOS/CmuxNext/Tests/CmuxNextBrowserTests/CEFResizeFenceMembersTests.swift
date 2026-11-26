import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Which resized pages a window's resize fence waits for (``CEFFenceMembers``). A page nobody sees seldom presents a
/// frame, so a fence that waits on it expires: every window-corner step of the page-sync bench waited on 5 pages for
/// the 4 shown (fd1 seed 1: 114 of 160 fences), the fifth the next Cmd-N's reserved workspace, mounted fully
/// transparent 100 000 pt off the content with its autoresizing on, so it takes the window's size each step. Without
/// lever 4a the expired fence's deadline waited for the main thread, and the window's commits stalled about 520 ms.
/// With ``CEFFenceMembers/shown`` only a page view that shows in its window joins, on both paths: in-tree pages and
/// layer-hosted pages in child windows. A page parked off the content (the New Tab spare), fully transparent, in a
/// hidden subtree (a background tab) or in no window joins none; a shown page still joins.
@MainActor
@Suite(.serialized, .closesItsWindows) struct CEFResizeFenceMembersTests {
    /// The fork's resize fence call of one in-tree page, counted.
    final class InTreeFork {
        private(set) var fences = 0
        let page = NSView()
        var calls: CEFInTreeCalls {
            CEFInTreeCalls(setInTreeHosting: { [self] _, container in container == nil ? nil : page },
                           contentView: { [self] _ in page },
                           resizeFence: { [self] _, _, _, done in
                               fences += 1
                               done(false)  // a page nobody sees never presents in time
                               return true
                           })
        }
    }

    /// The fork's resize fence call of one layer-hosted page, counted.
    final class HostedFork {
        private(set) var fences = 0
        var fork: CEFLayerHosting.Fork {
            CEFLayerHosting.Fork(setLayerHosting: { _, enabled in enabled ? 7 : 0 },
                                 resizeFence: { [self] _, _, _, done in
                                     fences += 1
                                     done(false)
                                     return true
                                 })
        }
    }

    static func makePort(_: CALayer) -> mach_port_t? {
        var name = mach_port_t(MACH_PORT_NULL)
        guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &name) == KERN_SUCCESS,
              mach_port_insert_right(mach_task_self_, name, name, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
              == KERN_SUCCESS else { return nil }
        return name
    }

    /// A borderless window off screen (400 x 300) with a layer-backed content view.
    static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.wantsLayer = true
        return window
    }

    /// Where a page view waits in the window, as the app mounts it.
    enum Place: CaseIterable, Sendable {
        /// A pane of the shown workspace: fills the content, resizes with the window.
        case shown
        /// The next Cmd-N's workspace (`WindowController.reservedContent`): `addPrewarmedSubview`, fully transparent,
        /// 100 000 pt off the content, resized with the window.
        case reservedWorkspace
        /// The New Tab spare (`PageOffscreenParking`): fully transparent, 100 000 pt off the content, fit to a pane's
        /// size after a resize settles.
        case offscreenParking
        /// Opaque, but 100 000 pt off the content.
        case offContent
        /// Over the content, but fully transparent (a parked workspace, `setParked(true)`).
        case transparent
        /// A background tab: in a hidden subtree of the shown workspace.
        case hiddenTab

        /// Mounts `page` (a page view sized to the content) in `window` here.
        @MainActor func mount(_ page: NSView, in window: NSWindow) {
            let content = window.contentView!
            let holder = NSView(frame: content.bounds)
            holder.autoresizingMask = [.width, .height]
            page.frame = holder.bounds
            page.autoresizingMask = [.width, .height]
            holder.addSubview(page)
            switch self {
            case .shown:
                content.addSubview(holder)
            case .reservedWorkspace:
                content.addPrewarmedSubview(holder)
            case .offscreenParking:
                holder.alphaValue = 0
                holder.autoresizingMask = []
                holder.frame = content.bounds.offsetBy(dx: -100_000, dy: -100_000)
                content.addSubview(holder)
            case .offContent:
                holder.frame = content.bounds.offsetBy(dx: -100_000, dy: -100_000)
                content.addSubview(holder)
            case .transparent:
                holder.alphaValue = 0
                content.addSubview(holder)
            case .hiddenTab:
                holder.isHidden = true
                content.addSubview(holder)
            }
        }
    }

    func withInTreeOn(_ body: () throws -> Void) rethrows {
        InTreePages.shared.setForTesting(requested: true, engine: .supported)
        defer { InTreePages.shared.setForTesting(requested: nil) }
        try body()
    }

    /// An in-tree page at `place` in `window`, on `fences`.
    func inTreePage(_ place: Place, in window: NSWindow, fences: CEFResizeFences) -> (CEFInTreeHosting, InTreeFork) {
        let host = CEFHostView(frame: .zero)
        place.mount(host, in: window)
        let fork = InTreeFork()
        let hosting = CEFInTreeHosting(schedule: { $0() }, resizeFences: fences)
        hosting.view = host
        #expect(hosting.pageWindowCreated(browser: 4, calls: fork.calls))
        return (hosting, fork)
    }

    /// The window takes a new size, as a window-corner step does: every page view resizes in the turn (the first
    /// resize of each only learns the window's size, then the window's own resize joins its fence).
    func resizeWindow(_ window: NSWindow, _ pages: [CEFInTreeHosting]) {
        pages.forEach { $0.pageViewResized() }
        window.setContentSize(NSSize(width: 520, height: 360))
        pages.forEach { $0.pageViewResized() }
        CFRunLoopRunInMode(.defaultMode, 0.005, false)  // the turn ends: the fence seals
    }

    /// The bug: a window resize with the next Cmd-N's workspace mounted waited on its page, which no one sees.
    @Test(arguments: Place.allCases.filter { $0 != .shown })
    func aWindowResizeWaitsOnlyForTheShownPages(_ place: Place) {
        withInTreeOn {
            let window = Self.makeWindow()
            defer { window.close() }
            let fences = CEFResizeFences(makePort: Self.makePort, members: .shown)
            let (shown, shownFork) = inTreePage(.shown, in: window, fences: fences)
            let (unseen, unseenFork) = inTreePage(place, in: window, fences: fences)
            resizeWindow(window, [shown, unseen])
            #expect(shownFork.fences == 2, "the shown page no longer holds the window's commit for its frame")
            #expect(unseenFork.fences == 0, "a window resize waited on a page nobody sees (\(place)): \(unseenFork.fences) fences")
        }
    }

    /// The New Tab spare is fit to a pane's size once a resize settles (`NewTabSparePool`): that resize joins no fence.
    @Test func theNewTabSparesFitAfterAResizeJoinsNoFence() {
        withInTreeOn {
            let window = Self.makeWindow()
            defer { window.close() }
            let fences = CEFResizeFences(makePort: Self.makePort, members: .shown)
            let (spare, spareFork) = inTreePage(.offscreenParking, in: window, fences: fences)
            spare.pageViewResized()
            spare.view?.superview?.setFrameSize(NSSize(width: 260, height: 300))
            spare.view?.setFrameSize(NSSize(width: 260, height: 300))
            spare.pageViewResized()
            #expect(spareFork.fences == 0, "the parked spare's fit held the window's commit for a frame no one sees")
        }
    }

    /// The spare Chromium window's page is in no pane and no cmux window: it joins nothing either way.
    @Test func aPageInNoWindowJoinsNoFence() {
        withInTreeOn {
            let fences = CEFResizeFences(makePort: Self.makePort, members: .shown)
            let host = CEFHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let fork = InTreeFork()
            let hosting = CEFInTreeHosting(schedule: { $0() }, resizeFences: fences)
            hosting.view = host
            #expect(hosting.pageWindowCreated(browser: 4, calls: fork.calls))
            hosting.pageViewResized()
            host.setFrameSize(NSSize(width: 520, height: 360))
            hosting.pageViewResized()
            #expect(fork.fences == 0)
        }
    }

    /// The shipped rule (``CEFFenceMembers/all``, the default until the bench measures `shown`): every resized page
    /// view in the window joins, the reserved workspace's too.
    @Test func everyResizedPageJoinsWithTheShippedRule() {
        withInTreeOn {
            let window = Self.makeWindow()
            defer { window.close() }
            let fences = CEFResizeFences(makePort: Self.makePort, members: .all)
            let (shown, shownFork) = inTreePage(.shown, in: window, fences: fences)
            let (reserved, reservedFork) = inTreePage(.reservedWorkspace, in: window, fences: fences)
            resizeWindow(window, [shown, reserved])
            #expect(shownFork.fences == 2)
            #expect(reservedFork.fences == 2)
        }
    }

    /// Layer-hosted pages (child windows, NIGHTLY's mode) take the same rule: a pane drag's resize and a zoom's
    /// announced resize join the window's fence only for a page that shows.
    @Test(arguments: Place.allCases)
    func aLayerHostedPageJoinsOnlyWhenItShows(_ place: Place) {
        let window = Self.makeWindow()
        defer { window.close() }
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        place.mount(view, in: window)
        let fork = HostedFork()
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { $0() },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                      refreshIntervals: { [1.0 / 60] },
                                      resizeFences: CEFResizeFences(makePort: Self.makePort, members: .shown))
        hosting.view = view
        hosting.pageWindowCreated(browser: 3, fork: fork.fork)
        #expect(hosting.page != nil)
        hosting.paneResizeDrag(active: true)
        hosting.pageViewResized()
        hosting.paneResizeDrag(active: false)
        hosting.paneCommitWillResize(true)
        hosting.pageViewResized()
        CFRunLoopRunInMode(.defaultMode, 0.005, false)
        if place == .shown {
            #expect(fork.fences == 2, "a shown layer-hosted page no longer joins its window's fence")
        } else {
            #expect(fork.fences == 0, "a layer-hosted page nobody sees (\(place)) held the window's commit: \(fork.fences) fences")
        }
    }

    /// A pane partly past the content's edge (a pane spring) still shows: its window resize joins the fence. A pane
    /// wholly past it (before the resize and after) joins none.
    @Test func aPagePartlyInsideTheContentJoinsAndOneWhollyOutsideDoesNot() {
        withInTreeOn {
            let window = Self.makeWindow()
            defer { window.close() }
            let fences = CEFResizeFences(makePort: Self.makePort, members: .shown)
            let (partly, partlyFork) = inTreePage(.shown, in: window, fences: fences)
            let (outside, outsideFork) = inTreePage(.shown, in: window, fences: fences)
            partly.view?.superview?.frame.origin.x = 300  // 100 of its 400 pt inside the 400 pt content, 220 of 520 after
            outside.view?.superview?.frame.origin.x = 600  // past the content's right edge at 400 pt and at 520 pt
            resizeWindow(window, [partly, outside])
            #expect(partlyFork.fences == 2, "a pane partly inside the content no longer holds the window's commit")
            #expect(outsideFork.fences == 0, "a window resize waited on a pane wholly outside the content: \(outsideFork.fences) fences")
        }
    }
}
