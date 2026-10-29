import AppKit
import CoreGraphics
import Testing

/// A diagnostic, not a test to land (branch cp/fix-tip-swift-s7-ui-probe): in the console Aqua session (worker
/// bc2167204e6c), can the test process become active, make a window key and see it visible, and does an animation
/// group complete? Tests the fleet-tooling agent's hypotheses: (1) NSApp never finished launching and no event is
/// dispatched, (2) macOS 14+ cooperative activation refuses a process that is not frontmost, (3) an occluded window
/// stops AppKit's animation clock. One synchronous test (no async run-loop pumping). Lines start with "S7ACT".
@MainActor @Suite(.serialized)
struct S7ActivationProbeTests {
    private func say(_ line: String) { print("S7ACT \(line)") }

    /// Dispatches NSApp's own events for `seconds`, as NSApplication.run would.
    private func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    private func state(_ label: String, _ window: NSWindow) {
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .contains { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
        say("\(label): policy=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive) running=\(NSApp.isRunning) "
            + "key=\(window.isKeyWindow) main=\(window.isMainWindow) onScreen=\(onScreen) "
            + "occlusionVisible=\(window.occlusionState.contains(.visible)) "
            + "frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
    }

    /// Every on-screen window above the normal level (layer > 0), with its owner: a system alert (UserNotificationCenter
    /// at layer 8) that holds the front may keep any other process from becoming active.
    private func windowsAbove(_ label: String) {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }
            .map { "\($0[kCGWindowOwnerName as String] ?? "?")@\($0[kCGWindowLayer as String] ?? "?")"
                + "(\($0[kCGWindowName as String] ?? ""))" }
        say("\(label) windows above layer 0 (\(list.count)): \(list.joined(separator: ", "))")
    }

    private func animationCompletes(_ window: NSWindow) -> String {
        let started = Date()
        var done: Date?
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            window.animator().setFrame(window.frame.insetBy(dx: 10, dy: 10), display: true)
        }, completionHandler: { done = Date() })
        pump(2)
        return done.map { String(format: "%.2f s", $0.timeIntervalSince(started)) } ?? "never (2 s)"
    }

    @Test func activationInTheConsoleSession() {
        _ = NSApplication.shared
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        say("session onConsole=\(session[kCGSessionOnConsoleKey as String] ?? "-") locked=\(session["CGSSessionScreenIsLocked"] ?? "absent")")
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 320, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        pump(0.3)
        state("as-is", window)
        windowsAbove("as-is")
        say("animation as-is: \(animationCompletes(window))")

        // Hypothesis 1: finish launching and dispatch NSApp's events.
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        pump(0.5)
        state("regular+finishLaunching+pump", window)

        // Hypothesis 2: activate with both APIs, then pump so the activation event is handled.
        NSApp.activate(ignoringOtherApps: true)
        pump(0.5)
        state("activate(ignoringOtherApps:)", window)
        windowsAbove("activate(ignoringOtherApps:)")
        if #available(macOS 14.0, *) {
            NSApp.activate()
            pump(0.5)
            state("activate() (cooperative)", window)
        windowsAbove("activate() (cooperative)")
        }
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
        pump(0.5)
        state("NSRunningApplication.activate", window)
        windowsAbove("NSRunningApplication.activate")
        window.makeKeyAndOrderFront(nil)
        pump(0.5)
        state("makeKeyAndOrderFront", window)

        // Hypothesis 3: does the animation clock run once (if) the window is visible?
        say("animation after activation attempts: \(animationCompletes(window))")

        // A non-activating panel: can it be key without the app active?
        let panel = NSPanel(contentRect: CGRect(x: 700, y: 300, width: 200, height: 120),
                            styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        defer { panel.orderOut(nil) }
        panel.makeKeyAndOrderFront(nil)
        pump(0.5)
        say("nonactivating panel: key=\(panel.isKeyWindow) occlusionVisible=\(panel.occlusionState.contains(.visible)) appActive=\(NSApp.isActive)")
    }
}
