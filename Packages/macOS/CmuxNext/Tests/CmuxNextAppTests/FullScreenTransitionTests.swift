import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// fullscreen-lag (user, 2026-10-19: "when I go to full screen there's a lot of lag and layout
/// issues"). A full screen enter or exit is one AppKit animation between two sizes: the content
/// takes the final size at once and nothing in it should spring, re-send or re-measure toward the
/// sizes in between, and when it ends the window's top row sits where it sits at rest.
///
/// AppKit's full screen needs a real Space, so these tests drive the transition through the
/// window's delegate calls and a private notification center, as AppKit would post them.
@MainActor @Suite(.serialized) struct FullScreenTransitionTests {
    // MARK: Motion: a transition is a resize the person does not drag

    @Test func aWindowIsInATransitionFromWillEnterToDidEnterAndFromWillExitToDidExit() {
        let center = NotificationCenter()
        let windows = LiveResizeWindows(center: center)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        center.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        #expect(windows.isActive, "the enter animation springs content toward sizes the next frame replaces")
        #expect(windows.isFullScreenTransitionActive)
        center.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        #expect(!windows.isActive)
        #expect(!windows.isFullScreenTransitionActive)
        center.post(name: NSWindow.willExitFullScreenNotification, object: window)
        #expect(windows.isActive, "the exit animation springs content toward sizes the next frame replaces")
        center.post(name: NSWindow.didExitFullScreenNotification, object: window)
        #expect(!windows.isActive)
        // A transition AppKit gives up on ends too (its delegate hears `windowDidFailToEnterFullScreen`).
        center.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        windows.endTransition(of: window)
        #expect(!windows.isActive, "a failed enter holds every spring forever")
        center.post(name: NSWindow.willExitFullScreenNotification, object: window)
        center.post(name: NSWindow.willCloseNotification, object: window)
        #expect(!windows.isActive, "a window closed mid-transition holds every spring forever")
    }

    // MARK: Terminals: one grid to the daemon, at the end

    final class Target: ResizeTarget {
        var applied: [CellSize] = []
        func applySettled(_ size: CellSize) { applied.append(size) }
        var awaitsEcho: Bool { false }
    }

    @Test func aTerminalSendsOneGridWhenTheTransitionEndsNotOnePerFrame() {
        var transitioning = true
        let coordinator = ResizeCoordinator(holds: { _ in transitioning })
        let target = Target()
        // Each frame of the animation lays the terminal out at another size.
        for (frame, cols) in [120, 160, 200, 240, 262].enumerated() {
            coordinator.submit(target, size: CellSize(cols: cols, rows: 40 + frame))
            _ = coordinator.tick()
        }
        #expect(target.applied.isEmpty, "the daemon reflowed the PTY for sizes the animation passed through: \(target.applied)")
        transitioning = false
        while coordinator.tick() {}
        #expect(target.applied == [CellSize(cols: 262, rows: 44)], "the final grid went \(target.applied)")
    }

    @Test func outsideATransitionTheGridGoesTheNextFrame() {
        let coordinator = ResizeCoordinator(holds: { _ in false })
        let target = Target()
        coordinator.submit(target, size: CellSize(cols: 100, rows: 30))
        _ = coordinator.tick()
        #expect(target.applied == [CellSize(cols: 100, rows: 30)], "a live resize or a divider drag is real time (perf I7)")
    }

    // MARK: The top row: where it rests, during and after

    private static func controller() throws -> (WindowController, AppServices) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"full-screen-top-row","workspace_key":"fs1"}"#.utf8))
        let state = WindowState(record: record)
        let controller = WindowController(state: state, services: services, frame: NSRect(x: 200, y: 200, width: 1100, height: 720))
        return (controller, services)
    }

    private static func lights(of window: NSWindow) -> [NSButton] {
        [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
    }

    private static func note(_ name: Notification.Name, _ window: NSWindow) -> Notification {
        Notification(name: name, object: window)
    }

    /// The toolbar band (sidebar toggle, Back, Forward) starts after the traffic lights.
    private static func bandMinX(_ controller: WindowController) -> CGFloat {
        controller.root.layoutSubtreeIfNeeded()
        return controller.root.toolbarBand.frame.minX
    }

    @Test func afterLeavingFullScreenTheToolbarBandIsBackAfterTheTrafficLights() throws {
        let (controller, _) = try Self.controller()
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let window = try #require(controller.window)
        let delegate: any NSWindowDelegate = controller
        let rest = Self.bandMinX(controller)
        try #require(rest > 40, "the band does not start after the traffic lights at rest (\(rest))")

        // Leaving full screen, AppKit lays the window out at its windowed size while the traffic
        // lights are still in the full screen titlebar (not this window's buttons yet), then puts
        // them back and posts didExit. Nothing else moves the window.
        delegate.windowWillExitFullScreen?(Self.note(NSWindow.willExitFullScreenNotification, window))
        for button in Self.lights(of: window) { button.isHidden = true }
        controller.root.needsLayout = true
        _ = Self.bandMinX(controller)
        for button in Self.lights(of: window) { button.isHidden = false }
        delegate.windowDidExitFullScreen?(Self.note(NSWindow.didExitFullScreenNotification, window))

        #expect(abs(Self.bandMinX(controller) - rest) < 0.5,
                "after full screen the sidebar toggle, Back and Forward sit under the traffic lights (\(Self.bandMinX(controller)) vs \(rest))")
    }

    @Test func whileLeavingFullScreenTheTopRowAlreadyKeepsClearOfTheTrafficLights() throws {
        let (controller, _) = try Self.controller()
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let window = try #require(controller.window)
        let delegate: any NSWindowDelegate = controller
        let rest = Self.bandMinX(controller)
        try #require(rest > 40, "the band does not start after the traffic lights at rest (\(rest))")
        delegate.windowWillEnterFullScreen?(Self.note(NSWindow.willEnterFullScreenNotification, window))
        delegate.windowDidEnterFullScreen?(Self.note(NSWindow.didEnterFullScreenNotification, window))

        // The exit animation shows the windowed layout as it grows back: the band must not start
        // at the window's edge and jump right when the lights come back after the animation.
        delegate.windowWillExitFullScreen?(Self.note(NSWindow.willExitFullScreenNotification, window))
        for button in Self.lights(of: window) { button.isHidden = true }
        controller.root.needsLayout = true
        let during = Self.bandMinX(controller)
        for button in Self.lights(of: window) { button.isHidden = false }
        delegate.windowDidExitFullScreen?(Self.note(NSWindow.didExitFullScreenNotification, window))
        #expect(abs(during - rest) < 0.5, "the band starts at \(during) during the exit animation and jumps to \(rest) after it")
    }
}
