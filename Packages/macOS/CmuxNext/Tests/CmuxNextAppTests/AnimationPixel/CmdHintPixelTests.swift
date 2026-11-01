import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextFocusUI
import CmuxNextTestSupport
import Foundation
import QuartzCore
import Testing

/// The hold-Cmd hint chips, judged on every 120 Hz frame the window server shows (Lawrence
/// 2026-11-01: "same for the hold cmd hover icon things"; plan in STATUS 2691). The real
/// `WindowScopedShortcutHintModifierMonitor` (ShortcutHintModifierPolicy's 300 ms intentional hold)
/// drives a real `ShortcutHintOverlayView` with its production fader in a key window:
///
/// - Every frame is exactly a blend of the two goldens, chips gone and chips shown (per channel
///   within ``tolerance``), at one opacity per frame; that opacity follows the declared fade
///   (fadeIn in, fadeOut out, easeOut) within ``fadeTolerance``, never steps back, and starts
///   the 300 ms hold after Cmd went down (in) or at once after it went up (out).
/// - A plain Cmd-click (a click before the hold ends) shows no chip in any frame.
/// - With every animation off the chips come and go in one frame.
/// - One case presses a REAL Cmd key through the HID event tap (CGEvent); without the right to
///   post events it fails.
///
/// Limits: the chips here are over a plain window, not over the sidebar, tabs and panes of the
/// app (the app's hint placement has its own tests); hovering a control while Cmd is held is not
/// covered yet.
@MainActor
@Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)),
       .enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1" || NSScreen.main != nil,
                "animation pixel tests draw on a display: a display step runs them and fails without a screen"))
struct CmdHintPixelTests {
    /// Per channel, at most one 8-bit step from the golden blend. Written here, never raised: a
    /// change needs its own commit with the reason and a reviewer receipt (cmux-ad 2026-11-01).
    static let tolerance = 1
    /// A frame's opacity at most this far from the declared fade at its time (1/255 is the step
    /// an 8-bit pixel can show; the fit over thousands of pixels is finer). Never raised.
    static let fadeTolerance = 2.0 / 255

    /// A key window (a borderless one cannot become key by default).
    final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    @MainActor
    final class Fixture {
        let display: VirtualDisplay120
        let window: KeyWindow
        let overlay = ShortcutHintOverlayView()
        var monitor: WindowScopedShortcutHintModifierMonitor?
        let hints: [ShortcutHintOverlayView.Hint]
        private let restore: () -> Void

        init(scale: Int, dark: Bool, animations: Bool) async throws {
            display = try await VirtualDisplay120(points: CGSize(width: 1200, height: 800), scale: scale)
            let design = DesignSettings.shared
            let saved = (design.animationsEnabled, design.animationSpeed, Motion.reduceMotionOverride)
            let restore = {
                design.animationsEnabled = saved.0
                design.animationSpeed = saved.1
                Motion.reduceMotionOverride = saved.2
            }
            self.restore = restore
            design.animationsEnabled = animations
            design.animationSpeed = .fast
            Motion.reduceMotionOverride = false
            let size = CGSize(width: 360, height: 120)
            hints = [
                .init(text: "⌘1", rect: CGRect(x: 20, y: 20, width: 140, height: 28)),
                .init(text: "⌘2", rect: CGRect(x: 20, y: 70, width: 140, height: 28)),
                .init(text: "⌘T", rect: CGRect(x: 200, y: 44, width: 140, height: 28)),
            ]
            let visible = display.screen.visibleFrame
            window = KeyWindow(contentRect: CGRect(x: (visible.minX + 60).rounded(), y: (visible.minY + 60).rounded(), width: size.width, height: size.height),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let content = FlippedView(frame: CGRect(origin: .zero, size: size))
            content.wantsLayer = true
            content.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
                : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.95, alpha: 1)).cgColor
            overlay.frame = content.bounds
            content.addSubview(overlay)
            window.contentView = content
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            let hints = hints
            let monitor = WindowScopedShortcutHintModifierMonitor(window: window) { [overlay] flags in overlay.hints = flags == nil ? [] : hints }
            self.monitor = monitor
            monitor.setEnabled(true)
            for _ in 0..<100 where !(NSApp.isActive && NSApp.keyWindow === window) { try await Task.sleep(for: .milliseconds(20)) }
            guard window.screen == display.screen, window.backingScaleFactor == CGFloat(scale), NSApp.isActive, NSApp.keyWindow === window else {
                let state = "screen \(window.screen?.localizedName ?? "none") \(window.backingScaleFactor)x, active \(NSApp.isActive), key \(NSApp.keyWindow === window)"
                close()
                throw VirtualDisplay120.Failure(description: "the hint window is not the active key window on the \(scale)x display: \(state)")
            }
        }

        func close() {
            monitor?.stop()
            window.closeAfterTest()
            restore()
        }

        /// A flags change through the monitor's own entrypoint (AppKit's local monitor calls it with the same event).
        func flags(_ flags: NSEvent.ModifierFlags) {
            guard let event = monitor?.debugEvent(flags, window: window) else { return }
            monitor?.receive(event)
        }
    }

    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    @Test(arguments: [1, 2], [false, true])
    func holdingCmdFadesTheChipsInAndReleasingFadesThemOutOnTheGoldens(scale: Int, dark: Bool) async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("the own-process window capture needs macOS 14.4")
            return
        }
        let fixture = try await Fixture(scale: scale, dark: dark, animations: true)
        defer { fixture.close() }
        let run = HintRun(fixture: fixture, name: "cmd-hints-\(scale)x-\(dark ? "dark" : "light")", scale: scale, dark: dark)
        AnimationPixelHarnessTests.record(try await run.holdAndRelease(animated: true) { fixture.flags(.command) } release: { fixture.flags([]) })
    }

    @Test(arguments: [1, 2])
    func withAnimationsOffTheChipsComeAndGoInOneFrame(scale: Int) async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("the own-process window capture needs macOS 14.4")
            return
        }
        let fixture = try await Fixture(scale: scale, dark: false, animations: false)
        defer { fixture.close() }
        let run = HintRun(fixture: fixture, name: "cmd-hints-off-\(scale)x", scale: scale, dark: false)
        AnimationPixelHarnessTests.record(try await run.holdAndRelease(animated: false) { fixture.flags(.command) } release: { fixture.flags([]) })
    }

    @Test(arguments: [1, 2])
    func aPlainCmdClickShowsNoChipInAnyFrame(scale: Int) async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("the own-process window capture needs macOS 14.4")
            return
        }
        let fixture = try await Fixture(scale: scale, dark: false, animations: true)
        defer { fixture.close() }
        let run = HintRun(fixture: fixture, name: "cmd-click-\(scale)x", scale: scale, dark: false)
        AnimationPixelHarnessTests.record(try await run.cmdClick {
            fixture.flags(.command)
        } click: {
            // The click arrives through the monitor's mouse-down path: it hides and suppresses until release.
            fixture.monitor?.keyDown()
        } release: { fixture.flags([]) })
    }

    /// A REAL Cmd key: down and up through the HID event tap, the path a person's keyboard takes.
    @Test func aRealHIDCmdHoldFadesTheChipsIn() async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("the own-process window capture needs macOS 14.4")
            return
        }
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            Issue.record("this process may not post HID events (Accessibility: post events): the real-key case cannot run here, which FAILS it")
            return
        }
        let fixture = try await Fixture(scale: 2, dark: false, animations: true)
        defer { fixture.close() }
        let run = HintRun(fixture: fixture, name: "cmd-hints-hid-2x", scale: 2, dark: false)
        func post(_ down: Bool) {
            let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 55, keyDown: down)
            event?.flags = down ? .maskCommand : []
            event?.post(tap: .cghidEventTap)
        }
        AnimationPixelHarnessTests.record(try await run.holdAndRelease(animated: true) { post(true) } release: { post(false) })
    }
}
