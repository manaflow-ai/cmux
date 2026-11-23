import AppKit
import CmuxNextDesign
import Foundation
@testable import CmuxNextUpdater
import Testing

/// `updates.keepWindowsDuringRestart` gates the relaunch afterimage (Leo 2026-11-23: "restart to update,
/// just do the normal close to update again"): off, a decided relaunch pictures nothing and the windows
/// leave the screen at once; on, the pictures start as before.
@MainActor @Suite(.serialized) struct UpdateWindowHandoffKeepWindowsTests {
    private static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "UpdateWindowHandoffKeepWindowsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func offIsTheDefaultAndStartsNoPictures() throws {
        _ = NSApplication.shared
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = UpdateWindowHandoff(unsaved: QuitUnsavedRegistry(), stateDirectory: root)
        var started = 0
        handoff.startsPictures = { started += 1 }
        handoff.relaunchDecided()
        #expect(started == 0)
    }

    /// Off, with the real afterimage: nothing is pictured, and `hide()` takes the window off screen in the same turn.
    @Test func offTheWindowsLeaveAtOnce() throws {
        _ = NSApplication.shared
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }
        let handoff = UpdateWindowHandoff(unsaved: QuitUnsavedRegistry(), stateDirectory: root) { false }
        handoff.relaunchDecided()
        #expect(handoff.hide())
        #expect(window.alphaValue == 0)
        #expect(window.ignoresMouseEvents)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: RelaunchAfterimage.folderName).path))
        // The same turn: no other test sees its windows hidden.
        handoff.restore()
        #expect(window.alphaValue == 1)
        #expect(!window.ignoresMouseEvents)
    }

    /// The setting is read as each relaunch is decided, not when the handoff is made.
    @Test func onStartsThePicturesAndIsReadAtTheRelaunch() throws {
        _ = NSApplication.shared
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        var keeps = false
        var started = 0
        let handoff = UpdateWindowHandoff(unsaved: QuitUnsavedRegistry(), stateDirectory: root) { keeps }
        handoff.startsPictures = { started += 1 }
        handoff.relaunchDecided()
        #expect(started == 0)
        keeps = true
        handoff.relaunchDecided()
        #expect(started == 1)
        keeps = false
        handoff.relaunchDecided()
        #expect(started == 1)
    }
}
