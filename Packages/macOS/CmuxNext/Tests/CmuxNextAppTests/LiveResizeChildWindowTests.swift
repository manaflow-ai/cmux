import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import QuartzCore
import Testing

/// A child panel belongs to its parent window's resize. AppKit sets `inLiveResize` and posts
/// `willStartLiveResize` and the full screen notifications for the dragged window only, and the
/// window overlay panel (`WindowOverlayHost`) is a child of it: the agent cursor layer is in that
/// panel while a Chromium page shows. So movement in a child panel snaps while its parent window
/// is in a live resize or a full screen transition, as movement in the parent does, and a child
/// of a window that is not resized keeps its movement.
///
/// A window enters a live resize through AppKit's notification, which a test posts to a private
/// center for its own window (`LiveResizePerWindowTests.tracked`). Every test is synchronous.
@MainActor @Suite(.serialized, .closesItsWindows) struct LiveResizeChildWindowTests {
    /// A window and a panel attached to it the way `WindowOverlayHost` attaches its overlay panel.
    @MainActor final class Family {
        /// Made at once (`defer: false`), as the app's windows are when a panel attaches to them.
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let child: NSPanel
        /// A panel of the panel (a popup over the overlay panel).
        let grandchild: NSPanel
        /// A layer in the child panel, as the agent cursor's host layer: `Motion.window(showing:)`
        /// resolves it to the panel, not to the parent window.
        let layer = CALayer()

        init() throws {
            child = Self.panel()
            grandchild = Self.panel()
            parent.addChildWindow(child, ordered: .above)
            child.addChildWindow(grandchild, ordered: .above)
            try #require(child.parent === parent && grandchild.parent === child, "AppKit did not attach the panels; the test proves nothing")
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            content.wantsLayer = true
            child.contentView = content
            try #require(content.layer != nil)
            content.layer?.addSublayer(layer)
            try #require(Motion.window(showing: layer) === child, "the layer must read as shown in the child panel")
        }

        static func panel() -> NSPanel {
            NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
        }

        func close() {
            if grandchild.parent === child { child.removeChildWindow(grandchild) }
            if child.parent === parent { parent.removeChildWindow(child) }
            grandchild.closeAfterTest()
            child.closeAfterTest()
            parent.closeAfterTest()
        }
    }

    static let gates: [MotionGate] = LiveResizePerWindowTests.gates + [Motion.cursor]

    @Test func aChildPanelSnapsWhileItsParentWindowIsInALiveResize() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try #require(Motion.cursor.animatesMovement, "animation speed is off on this host")
        let family = try Family()
        defer { family.close() }
        LiveResizePerWindowTests.tracked { center in
            #expect(!Motion.isLiveResizing(family.child), "nothing is resized yet")
            center.post(name: NSWindow.willStartLiveResizeNotification, object: family.parent)
            #expect(Motion.isLiveResizing(family.child), "a child panel is in its parent window's live resize")
            #expect(Motion.isLiveResizing(family.grandchild), "a panel of a child panel is in the window's live resize too")
            for gate in Self.gates {
                #expect(gate.policy(in: family.child).liveResize, "\(gate.category): the policy of a child panel reads its parent's live resize")
                #expect(!gate.animatesMovement(in: family.child), "\(gate.category): movement in a child panel springs toward a place the next frame replaces")
                #expect(!gate.animatesMovement(in: family.grandchild), "\(gate.category): movement in a panel of a child panel")
                #expect(gate.policy(in: family.child).animatesFades, "a live resize stops no fade")
            }
            // The read the agent cursor makes (AgentCursorStack): the window that shows its host layer.
            #expect(!Motion.cursor.animatesMovement(in: Motion.window(showing: family.layer)),
                    "an agent cursor in the overlay panel glides during a live resize of its window")
            center.post(name: NSWindow.didEndLiveResizeNotification, object: family.parent)
            #expect(!Motion.isLiveResizing(family.child), "the resize ended")
            for gate in Self.gates {
                #expect(gate.animatesMovement(in: family.child), "\(gate.category): the resize ended; movement in the child panel animates again")
            }
        }
    }

    @Test func aChildPanelSnapsWhileItsParentWindowChangesFullScreen() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try #require(Motion.cursor.animatesMovement, "animation speed is off on this host")
        let family = try Family()
        defer { family.close() }
        LiveResizePerWindowTests.tracked { center in
            for (start, end) in [(NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification),
                                 (NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification)] {
                center.post(name: start, object: family.parent)
                #expect(Motion.isLiveResizing(family.child), "a child panel is in its parent window's full screen transition")
                for gate in Self.gates {
                    #expect(gate.policy(in: family.child).liveResize, "\(gate.category): the policy of a child panel reads its parent's transition")
                    #expect(!gate.animatesMovement(in: family.child), "\(gate.category): movement in a child panel springs inside the transition")
                    #expect(!gate.animatesMovement(in: family.grandchild), "\(gate.category): movement in a panel of a child panel")
                }
                #expect(!Motion.cursor.animatesMovement(in: Motion.window(showing: family.layer)),
                        "an agent cursor in the overlay panel glides during a full screen transition of its window")
                center.post(name: end, object: family.parent)
                #expect(!Motion.isLiveResizing(family.child), "the transition ended")
                for gate in Self.gates {
                    #expect(gate.animatesMovement(in: family.child), "\(gate.category): the transition ended; movement in the child panel animates again")
                }
            }
        }
    }

    @Test func aChildPanelOfAWindowThatIsNotResizedKeepsItsMovement() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try #require(Motion.cursor.animatesMovement, "animation speed is off on this host")
        let resized = try Family(), other = try Family()
        defer { resized.close(); other.close() }
        LiveResizePerWindowTests.tracked { center in
            for (start, end) in [(NSWindow.willStartLiveResizeNotification, NSWindow.didEndLiveResizeNotification),
                                 (NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification)] {
                center.post(name: start, object: resized.parent)
                #expect(!Motion.isLiveResizing(other.child) && !Motion.isLiveResizing(other.grandchild),
                        "a child panel of another window is not in this window's resize")
                for gate in Self.gates {
                    #expect(!gate.policy(in: other.child).liveResize)
                    #expect(gate.animatesMovement(in: other.child), "\(gate.category): a resize of one window snaps movement in another window's child panel")
                }
                #expect(Motion.cursor.animatesMovement(in: Motion.window(showing: other.layer)),
                        "an agent cursor in another window's overlay panel lands at once")
                center.post(name: end, object: resized.parent)
            }
        }
    }

    /// The parent's own state does not leak down to a panel that left it.
    @Test func aPanelThatLeftItsParentIsNotInTheParentsResize() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try #require(Motion.cursor.animatesMovement, "animation speed is off on this host")
        let family = try Family()
        defer { family.close() }
        LiveResizePerWindowTests.tracked { center in
            center.post(name: NSWindow.willStartLiveResizeNotification, object: family.parent)
            family.parent.removeChildWindow(family.child)
            #expect(!Motion.isLiveResizing(family.child))
            #expect(Motion.cursor.animatesMovement(in: family.child))
        }
    }
}
