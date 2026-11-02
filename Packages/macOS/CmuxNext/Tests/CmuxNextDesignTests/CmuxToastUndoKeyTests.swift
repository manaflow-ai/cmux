import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Cmd-Z runs only the newest undo toast of a window (`CmuxToastStack.newestUndo`), so only that
/// toast's Undo shows ⌘Z in its tooltip; when it goes, the next newest shows it again.
@MainActor
@Suite(.closesItsWindows)
struct CmuxToastUndoKeyTests {
    @Test func onlyTheNewestUndoToastShowsCmdZ() throws {
        let host = UndoKeyToastHost()
        let center = CmuxToastCenter(host: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let first = center.show(CmuxToast(id: "tab-closed", message: "Closed “zsh”", action: .undo()), in: window)
        let newer = center.show(CmuxToast(id: "pane-closed", message: "Closed a pane", action: .undo()), in: window)
        let notice = center.show(CmuxToast(id: "notice", message: "Copied"), in: window)
        let older = try #require(host.shown.first?.actionButton)
        let newest = try #require(host.shown.dropFirst().first?.actionButton)
        #expect(newest.themedToolTipShortcut == CmuxToastStrings.undoShortcut)
        #expect(older.themedToolTipShortcut == nil)
        #expect(older.accessibilityHelp() == nil, "an older Undo's help still names a key that runs the newer one")

        newer.dismiss()
        #expect(older.themedToolTipShortcut == CmuxToastStrings.undoShortcut)
        #expect(older.accessibilityHelp() == CmuxToastStrings.undoShortcut)
        first.dismiss()
        notice.dismiss()
    }
}

private final class UndoKeyToastHost: CmuxToastHosting {
    private(set) var shown: [CmuxToastView] = []
    func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, appearing: Bool, windowGone: @escaping () -> Void) {
        shown.append(toast)
    }
    func move(_ toast: CmuxToastView, to slot: Int) {}
    func hide(_ toast: CmuxToastView, animated: Bool) {}
}
