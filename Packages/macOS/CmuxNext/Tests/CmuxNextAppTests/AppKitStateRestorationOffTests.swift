import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextFiles
@testable import CmuxNextFilesUI
import CmuxNextWakeups
import Foundation
import Testing

/// cmux restores its windows itself (window registry and daemon), so AppKit state restoration is
/// off: every titled window cmux makes is `isRestorable = false`, so AppKit encodes none of them into Saved
/// Application State and restores none at launch.
@MainActor struct AppKitStateRestorationOffTests {
    @Test func aMainWindowIsNotRestorable() {
        _ = NSApplication.shared
        let window = ShellWindow.main(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        defer { window.close() }
        #expect(!window.isRestorable)
    }

    /// `install(kind:content:scope:)` makes every installed window titled, so it also makes it not restorable.
    @Test func anInstalledWindowIsNotRestorable() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.install(kind: .main, content: NSView(), scope: ThemeScope(level: .room))
        #expect(window.styleMask.contains(.titled))
        #expect(!window.isRestorable)
    }

    @Test func aFileInfoWindowIsNotRestorable() {
        _ = NSApplication.shared
        let info = FileInfoWindow(url: FileManager.default.temporaryDirectory, icons: FileIconProvider(queries: nil),
                                  mainWork: MainWorkScheduler(budget: MainFrameBudget()),
                                  reader: FileInfoReader(work: BackgroundWork(label: "test.file-info"))) {}
        defer { info.panel.close() }
        #expect(!info.panel.isRestorable)
    }

    @Test func theAppDelegateSupportsSecureRestorableState() {
        #expect(AppDelegate.instancesRespond(to: #selector(NSApplicationDelegate.applicationSupportsSecureRestorableState(_:))))
    }
}
