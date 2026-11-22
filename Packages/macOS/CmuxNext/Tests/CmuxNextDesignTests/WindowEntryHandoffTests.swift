import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// ``WindowEntryHandoff``: a container in no window that shows a view in a window gets the view when
/// it enters the window, unless the view moved meanwhile.
@MainActor
@Suite(.closesItsWindows)
struct WindowEntryHandoffTests {
    final class Scene {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let parking = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        init() {
            _ = NSApplication.shared
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.addSubview(parking)
            parking.addSubview(view)
        }
    }

    // `defers` and `entered` are mutating: each runs outside #expect, which cannot call a mutating
    // member on the value it captures.
    @Test func aViewInTheWindowWaitsForAHostOutsideIt() {
        let scene = Scene()
        defer { scene.window.close() }
        var handoff = WindowEntryHandoff()
        let deferred = handoff.defers(scene.view, to: scene.host)
        #expect(deferred)
        let beforeEntry = handoff.entered(scene.host)
        #expect(beforeEntry == nil, "the host is still in no window")
        scene.root.addSubview(scene.host)
        let handedOver = handoff.entered(scene.host)
        #expect(handedOver === scene.view)
        let second = handoff.entered(scene.host)
        #expect(second == nil, "it waits once")
    }

    @Test func aViewThatMovedMeanwhileIsNotHandedOver() {
        let scene = Scene()
        defer { scene.window.close() }
        var handoff = WindowEntryHandoff()
        let deferred = handoff.defers(scene.view, to: scene.host)
        #expect(deferred)
        scene.root.addSubview(scene.view)
        scene.root.addSubview(scene.host)
        let handedOver = handoff.entered(scene.host)
        #expect(handedOver == nil)
    }

    @Test(arguments: [false, true])
    func noWaitWhenTheHostIsInAWindowOrTheViewIsNot(hostInWindow: Bool) {
        let scene = Scene()
        defer { scene.window.close() }
        if hostInWindow { scene.root.addSubview(scene.host) } else { scene.view.removeFromSuperview() }
        var handoff = WindowEntryHandoff()
        let deferred = handoff.defers(scene.view, to: scene.host)
        #expect(!deferred)
    }

    @Test func aViewAddedNowForgetsTheOneThatWaited() {
        let scene = Scene()
        defer { scene.window.close() }
        var handoff = WindowEntryHandoff()
        let deferred = handoff.defers(scene.view, to: scene.host)
        #expect(deferred)
        scene.root.addSubview(scene.host)
        let other = NSView()
        let otherDeferred = handoff.defers(other, to: scene.host)
        #expect(!otherDeferred)
        let handedOver = handoff.entered(scene.host)
        #expect(handedOver == nil)
    }
}
