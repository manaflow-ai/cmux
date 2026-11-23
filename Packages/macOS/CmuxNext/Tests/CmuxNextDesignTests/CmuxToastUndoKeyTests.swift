import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Cmd-Z runs only the newest undo toast of a window (`CmuxToastStack.newestUndo`), so only that
/// toast is shown with the key (`CmuxToastShown.showsUndoKey`, ⌘Z on its Undo); when it goes, the
/// next newest shows it again.
@MainActor
@Suite(.closesItsWindows)
struct CmuxToastUndoKeyTests {
    @Test func onlyTheNewestUndoToastShowsCmdZ() {
        let host = UndoKeyToastHost()
        let center = CmuxToastCenter(host: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let first = center.show(CmuxToast(id: "tab-closed", message: "Closed “zsh”", action: .undo()), in: window)
        let newer = center.show(CmuxToast(id: "pane-closed", message: "Closed a pane", action: .undo()), in: window)
        let notice = center.show(CmuxToast(id: "notice", message: "Copied"), in: window)
        #expect(host.shown.map(\.toast.id) == ["tab-closed", "pane-closed", "notice"])
        #expect(host.shown.map(\.showsUndoKey) == [false, true, false], "an older Undo still names a key that runs the newer one")

        newer.dismiss()
        #expect(host.shown.map(\.toast.id) == ["tab-closed", "notice"])
        #expect(host.shown.map(\.showsUndoKey) == [true, false])
        first.dismiss()
        notice.dismiss()
        #expect(host.shown.isEmpty)
    }
}

/// Keeps the window's toasts as the center last showed them.
@MainActor
private final class UndoKeyToastHost: CmuxToastHosting {
    private(set) var shown: [CmuxToastShown] = []
    func show(_ toasts: [CmuxToastShown], in window: NSWindow, center: CmuxToastCenter) {
        shown = toasts
    }
}
