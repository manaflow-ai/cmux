import AppKit
@testable import CmuxNextApp
import Testing

/// p08-startup-087: cmux restores its windows itself (window registry and daemon), so AppKit state restoration is
/// off. A main window (live or the launch picture's) is not restorable, and the app delegate answers the secure
/// restoration questions so AppKit neither writes nor reads Saved Application State.
@MainActor struct AppKitStateRestorationOffTests {
    @Test func aMainWindowIsNotRestorable() {
        _ = NSApplication.shared
        let window = ShellWindow.main(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        defer { window.close() }
        #expect(!window.isRestorable)
    }

    @Test func theAppDelegateAnswersTheSecureRestorationQuestions() {
        let selectors = [
            #selector(NSApplicationDelegate.applicationSupportsSecureRestorableState(_:)),
            #selector(NSApplicationDelegate.application(_:shouldSaveSecureApplicationState:)),
            #selector(NSApplicationDelegate.application(_:shouldRestoreSecureApplicationState:)),
        ]
        for selector in selectors {
            #expect(AppDelegate.instancesRespond(to: selector), "AppKit asks \(selector); an unanswered one restores")
        }
    }
}
