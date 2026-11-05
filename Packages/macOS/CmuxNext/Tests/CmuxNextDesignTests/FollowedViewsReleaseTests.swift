import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S7, the end of a `FollowedViews` hold. `endHold()` turns the held views' frame notices on again,
/// and AppKit posts each held notice inside that call: the observers run in the middle of the release. Review of
/// ec8aedb298a (Codex): a hold that such an observer starts then (a resize of the window from a frame notice, or the
/// DEBUG hold across the commit, `LiveResizeDragInput.holdForCommit`) took only the views already turned on, and the
/// release then turned the others on under it; it also took the geometry posts the release had not delivered yet. A
/// release now ends before another hold can begin: a hold asked for during it does not start (the release still going
/// covers the frame changes made then), and a geometry post made during it goes at once.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct FollowedViewsReleaseTests {
    /// A window with a container in its content view and a followed view in the container.
    @MainActor final class Rig {
        let window: NSWindow
        let container: NSView
        let followed: NSView
        let views: FollowedViews

        init() {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            followed = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            container.addSubview(followed)
            window.contentView?.addSubview(container)
            for view in [followed, container] { view.postsFrameChangedNotifications = true }
            views = FollowedViews.of(window)
            views.add(followed)
        }

        func close() {
            views.remove(followed)
            window.close()
        }

        /// The chain the follower observes, from the followed view to the top.
        var chain: [NSView] {
            var chain: [NSView] = [], view: NSView? = followed
            while let current = view {
                chain.append(current)
                view = current.superview
            }
            return chain
        }
    }

    /// What the observers saw.
    @MainActor final class Log {
        var containerNotices = 0
        var startedDuringRelease = false
        var heldDuringRelease: Bool?
        var order: [String] = []
        var ends = 0
    }

    /// An observer of the followed view's frame notice asks for a hold while the first hold's notices go and changes the
    /// container's frame: when the first release returns, nothing holds, every view of the chain posts frame notices
    /// again, and the container's change reached its observers.
    @Test func aHoldAskedForWhileAnotherHoldsNoticesGoDoesNotStart() {
        let rig = Rig(), log = Log()
        defer { rig.close() }
        // global-notice-allow: AppKit posts frame notices on the default center (only observed here, never posted)
        let containerObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: rig.container, queue: nil) { _ in
            MainActor.assumeIsolated { log.containerNotices += 1 } // main-proof: AppKit posts frame notices on the main thread
        }
        // global-notice-allow: AppKit posts frame notices on the default center (only observed here, never posted)
        let followedObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: rig.followed, queue: nil) { _ in
            MainActor.assumeIsolated { // main-proof: AppKit posts frame notices on the main thread
                guard !log.startedDuringRelease else { return }
                log.startedDuringRelease = true
                rig.views.beginHold()
                rig.container.setFrameSize(NSSize(width: 320, height: 210))
            }
        }
        defer {
            NotificationCenter.default.removeObserver(containerObserver)
            NotificationCenter.default.removeObserver(followedObserver)
        }

        rig.views.beginHold()
        rig.followed.setFrameSize(NSSize(width: 220, height: 110))
        rig.container.setFrameSize(NSSize(width: 310, height: 205))
        rig.views.endHold()

        #expect(log.startedDuringRelease, "the followed view's held notice did not reach its observer")
        #expect(!rig.views.isHolding, "a hold asked for during the release is holding after it")
        let off = rig.chain.filter { !$0.postsFrameChangedNotifications }.map { "\(type(of: $0))" }
        #expect(off.isEmpty, "views that post no frame notices after the release: \(off)")
        #expect(log.containerNotices >= 1, "the container's frame changes reached no observer")
        // The caller of the second hold ends it later: nothing is left to let go.
        rig.views.endHold()
        let allPost = rig.chain.allSatisfy { $0.postsFrameChangedNotifications }
        #expect(allPost, "a view of the chain posts no frame notices after the second hold's end")
    }

    /// A geometry post that an observer makes during the release goes at once: no hold keeps it.
    @Test func aGeometryPostMadeDuringTheReleaseGoesAtOnce() {
        let rig = Rig(), log = Log()
        defer { rig.close() }
        let poster = NSView(frame: .zero)
        rig.container.addSubview(poster)
        // global-notice-allow: AppKit posts frame notices on the default center (only observed here, never posted)
        let observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: rig.followed, queue: nil) { _ in
            MainActor.assumeIsolated { // main-proof: AppKit posts frame notices on the main thread
                guard log.heldDuringRelease == nil else { return }
                log.heldDuringRelease = rig.views.holdsGeometryPost(of: poster) { log.ends += 1 }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        rig.views.beginHold()
        rig.followed.setFrameSize(NSSize(width: 230, height: 120))
        rig.views.endHold()

        #expect(log.heldDuringRelease == false, "a post made during the release was held")
        #expect(log.ends == 0, "a post that was not held came back at the end of a hold")
    }

    /// A post held in a hold comes back once, at its end, after the frame notices.
    @Test func aHeldPostComesBackOnceAfterTheFrameNotices() {
        let rig = Rig(), log = Log()
        defer { rig.close() }
        let poster = NSView(frame: .zero)
        rig.container.addSubview(poster)
        // global-notice-allow: AppKit posts frame notices on the default center (only observed here, never posted)
        let observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: rig.followed, queue: nil) { _ in
            MainActor.assumeIsolated { log.order.append("frame") } // main-proof: AppKit posts frame notices on the main thread
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        rig.views.beginHold()
        rig.followed.setFrameSize(NSSize(width: 240, height: 130))
        let held = rig.views.holdsGeometryPost(of: poster) { log.order.append("post") }
        let heldAgain = rig.views.holdsGeometryPost(of: poster) { log.order.append("second post") }
        #expect(held, "the hold did not keep the post")
        #expect(heldAgain, "a second post of the same view in the hold was not kept")
        rig.views.endHold()

        #expect(log.order == ["frame", "post"], "the end of the hold delivered \(log.order)")
    }
}
