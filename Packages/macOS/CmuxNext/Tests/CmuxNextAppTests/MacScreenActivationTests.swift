import AppKit
@testable import CmuxNextMacScreen
import Testing

/// Mac Screen follows app activation and window key state through its observers on an injected
/// center (`MacScreenShareHost.activate()`, `MacScreenSystemShortcuts.start()`): a post on main runs
/// the handler inline, so the state reads new at once after the post.
@MainActor
struct MacScreenActivationTests {
    /// Permission answers that a test changes between posts (a class: the check closures capture it).
    private final class Answers {
        var granted = false
        var checks = 0
    }

    @Test func theShareHostRechecksPermissionsWhenTheAppBecomesActive() {
        let center = NotificationCenter()
        let answers = Answers()
        let host = MacScreenShareHost(center: center)
        host.checkScreenRecording = { answers.granted }
        host.checkAccessibility = { answers.granted }
        host.activate()
        #expect(!host.screenRecordingGranted && !host.accessibilityGranted)
        answers.granted = true
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(!host.screenRecordingGranted)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(host.screenRecordingGranted && host.accessibilityGranted)
    }

    @Test func theShareHostStopsObservingWhenReleased() {
        let center = NotificationCenter()
        let answers = Answers()
        var host: MacScreenShareHost? = MacScreenShareHost(center: center)
        host?.checkScreenRecording = { answers.checks += 1; return false }
        host?.activate()
        let checked = answers.checks
        host = nil
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(answers.checks == checked)
    }

    @Test func systemShortcutsRecheckAccessibilityOnlyWhenTheAppBecomesActive() {
        let center = NotificationCenter()
        let answers = Answers()
        let shortcuts = MacScreenSystemShortcuts(host: MacScreenShareHost(center: center), center: center)
        shortcuts.checkAccessibility = { answers.checks += 1; return answers.granted }
        shortcuts.isAppActive = { false }
        shortcuts.start()
        #expect(!shortcuts.accessibilityGranted)
        answers.granted = true
        let checked = answers.checks
        for name in [NSApplication.didResignActiveNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.post(name: name, object: nil)
        }
        #expect(answers.checks == checked)
        #expect(!shortcuts.accessibilityGranted)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(answers.checks == checked + 1)
        #expect(shortcuts.accessibilityGranted)
    }
}
