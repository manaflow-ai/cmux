import AppKit
import CmuxNextTestGUIHost
import Testing

/// A diagnostic, not a test to land (branch cp/fix-tip-swift-s7-gui-host): the GUI host made the process active
/// and ordered a window front, yet the window never became key and NSApp.isActive read false (proof 82017f7a).
/// The activation probe got there with `nextEvent(matching:until:+20 ms,inMode:.default)`, a call that runs the
/// run loop in the default mode; the host only drains with `distantPast` from an observer. Each case waits the
/// same 3 s one way and logs active/key. Every line starts with "S7PUMP".
@MainActor @Suite(.serialized)
struct S7HostPumpProbeTests {
    private func say(_ line: String) { print("S7PUMP \(line)") }

    private func window(_ name: String) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 320, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = name
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func report(_ name: String, _ window: NSWindow) {
        say("\(name): hostRunning=\(cmux_next_test_gui_host_running()) hostActivated=\(cmux_next_test_gui_host_activated()) "
            + "active=\(NSApp.isActive) key=\(window.isKeyWindow) keyWindow=\(NSApp.keyWindow?.title ?? "nil") "
            + "mode=\(RunLoop.current.currentMode?.rawValue ?? "nil") frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
    }

    @Test func a1AsyncSleepOnly() async throws {
        for _ in 0..<200 where cmux_next_test_gui_host_running() == 0 { await Task.yield() }
        let w = window("async-sleep"); defer { w.orderOut(nil) }
        try await Task.sleep(for: .seconds(3))
        report("async Task.sleep 3 s", w)
    }

    @Test func a2DrainDistantPast() throws {
        let w = window("drain-distant-past"); defer { w.orderOut(nil) }
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        report("drain distantPast 3 s (busy)", w)
    }

    @Test func a3NextEventWaitingDefaultMode() throws {
        let w = window("next-event-20ms"); defer { w.orderOut(nil) }
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        report("nextEvent until +20 ms in .default 3 s", w)
    }

    @Test func a4RunLoopDefaultModeThenDrain() throws {
        let w = window("runloop-default"); defer { w.orderOut(nil) }
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        report("RunLoop.run(.default) 3 s (observer drains)", w)
    }

    @Test func a5ActivateAgainThenWait() throws {
        NSApp.activate(ignoringOtherApps: true)
        let w = window("activate-again"); defer { w.orderOut(nil) }
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        report("activate again + nextEvent 20 ms 3 s", w)
    }
}
