import AppKit
import Bonsplit
import Foundation
import SwiftUI
import Testing

@MainActor
private final class DeferredRefreshProbe {
    var ran = false
}

/// cmux #20181/#20194: cmux 0.65.1 trapped with "No Observable object of type
/// BonsplitController found" when a deferred terminal refresh
/// (`WindowTerminalPortal.deferSurfaceRefresh` -> `refreshSurfaceNow` ->
/// `displayIfNeeded`) laid the window out while a pane host had left
/// `BonsplitView`. A pane host is its own `NSHostingView`; it read the
/// controller only through `BonsplitView`'s environment until bonsplit
/// 093f774 gave every pane host its controllers explicitly.
///
/// This drives the same order as the crash without the app: a deferred
/// main-queue refresh is queued, a pane host leaves `BonsplitView` but stays in
/// the window, then the queue drains and the refresh's `displayIfNeeded` lays
/// the window out. The pin before the fix traps; the fixed pin passes.
@Suite("Detached pane host refresh", .serialized)
@MainActor
struct PaneHostDetachedRefreshTests {
    @Test("A deferred refresh after a pane host leaves BonsplitView does not trap")
    func deferredRefreshAfterPaneHostLeavesBonsplitView() async throws {
        print("PaneHostDetachedRefreshTests: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        _ = NSApplication.shared
        let controller = BonsplitController()
        controller.createTab(title: "Left")
        let bonsplitHost = NSHostingView(rootView:
            BonsplitView(controller: controller) { tab, _ in Text(tab.title) } emptyPane: { _ in Color.clear }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView)
        // A headless test host can leave the window's content view 1x0, so
        // size the views explicitly instead of following the content view.
        contentView.setFrameSize(NSSize(width: 900, height: 600))
        bonsplitHost.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        contentView.addSubview(bonsplitHost)
        // Stand-in for the terminal portal's hosted surface: an AppKit view in
        // the same window, outside BonsplitView, whose refresh is deferred.
        let surfaceStandIn = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        contentView.addSubview(surfaceStandIn)
        window.makeKeyAndOrderFront(nil)
        Self.settle(window)

        let firstPane = try #require(controller.focusedPaneId)
        _ = try #require(controller.splitPane(firstPane, orientation: .horizontal))
        Self.settle(window)
        var paneHosts = Self.paneHosts(in: bonsplitHost)
        for _ in 0..<400 where paneHosts.count < 2 {
            CFRunLoopRunInMode(.defaultMode, 0.005, true)
            window.displayIfNeeded()
            contentView.layoutSubtreeIfNeeded()
            paneHosts = Self.paneHosts(in: bonsplitHost)
        }
        if paneHosts.count != 2 {
            print("PaneHostDetachedRefreshTests: view tree\n" + Self.describeTree(contentView))
        }
        #expect(paneHosts.count == 2, "a two-pane split mounts two pane hosts")
        let paneHost = try #require(paneHosts.first)

        // 1. Queue the deferred refresh, as deferSurfaceRefresh does.
        let refresh = DeferredRefreshProbe()
        DispatchQueue.main.async {
            surfaceStandIn.displayIfNeeded()
            refresh.ran = true
        }

        // 2. Before it runs, the pane host leaves BonsplitView but stays in
        //    the window and still needs layout.
        paneHost.removeFromSuperview()
        contentView.addSubview(paneHost)
        paneHost.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        paneHost.needsLayout = true
        surfaceStandIn.needsDisplay = true
        // A drop also moves focus. Every pane's body reads it, so the detached
        // host has a pending SwiftUI update when the window next lays out.
        let otherPane = try #require(controller.allPaneIds.first { $0 != controller.focusedPaneId })
        controller.focusPane(otherPane)
        #expect(paneHost.window === window)
        #expect(!paneHost.isDescendant(of: bonsplitHost))

        // 3. Drain the main queue: the refresh lays the window out.
        //    Swift Testing runs this test as a main-queue job, so the queue
        //    drains only while the test is suspended, not inside RunLoop.run.
        for _ in 0..<5 where !refresh.ran {
            await Self.drainMainQueue()
        }
        #expect(refresh.ran)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        #expect(paneHost.window === window)
        paneHost.removeFromSuperview()
    }

    private static func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func settle(_ window: NSWindow) {
        for _ in 0..<5 {
            window.displayIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func describeTree(_ view: NSView, depth: Int = 0) -> String {
        var line = String(repeating: "  ", count: depth)
            + String(describing: type(of: view)) + " " + NSStringFromClass(type(of: view))
            + " \(view.frame)\n"
        guard depth < 24 else { return line }
        for subview in view.subviews { line += describeTree(subview, depth: depth + 1) }
        return line
    }

    /// Bonsplit's per-pane hosting views: the `NSHostingView` each split
    /// arranged container (`SplitArrangedContainerView`, internal to Bonsplit,
    /// so matched by type name) holds.
    private static func paneHosts(in root: NSView) -> [NSView] {
        var found: [NSView] = []
        func visit(_ view: NSView) {
            if view !== root,
               view is NSHostingView<AnyView>,
               let parent = view.superview,
               String(describing: type(of: parent)).contains("SplitArrangedContainerView") {
                found.append(view)
                return
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }
}
