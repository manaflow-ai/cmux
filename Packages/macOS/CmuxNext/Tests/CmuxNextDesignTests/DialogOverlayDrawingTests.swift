import AppKit
@testable import CmuxNextDesign
import Testing

/// Review of #37296: (F1) the dialog's view took the keyboard itself, a plain view that refuses it, so
/// the page under it never got the keyboard and nobody could type into a text field; (F2) a tab switch
/// hid a tab's dialog and the next show asked the drawing for a new view, loading a page per switch
/// while the old one was never given back. The host now asks its drawing for one view per dialog,
/// hands the keyboard to the drawing on every show, and gives the view back only when the dialog ends.
@MainActor @Suite struct DialogOverlayDrawingTests {
    /// Counts what the host asks of its drawing.
    @MainActor private final class Drawing: CmuxDialogDrawing {
        var attached = 0, focused = 0, detached = 0
        func attach(_ dialog: CmuxDialogPresentation, in window: NSWindow?) -> NSView? {
            attached += 1
            return NSView()
        }
        func focus(_ dialog: CmuxDialogPresentation) { focused += 1 }
        func detach(_ dialog: CmuxDialogPresentation) { detached += 1 }
    }

    private static func window() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tab = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView?.addSubview(tab)
        return (window, tab)
    }

    @Test func aShownDialogGivesItsDrawingTheKeyboard() {
        let drawing = Drawing()
        let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(drawing: drawing, activate: {}, isAppActive: { true }))
        let (window, _) = Self.window()
        defer { window.close() }
        let id = center.present(CmuxDialogSpec(title: "Rename", fields: [.text("name")], buttons: [.cancel(), .ok()]),
                                in: .window(window)) { _ in }
        #expect(drawing.attached == 1)
        #expect(drawing.focused == 1)
        center.dismiss(id)
        #expect(drawing.detached == 1)
    }

    @Test func aTabSwitchKeepsTheDialogsOneView() {
        let drawing = Drawing()
        let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(drawing: drawing, activate: {}, isAppActive: { true }))
        let (window, tab) = Self.window()
        defer { window.close() }
        let id = center.present(CmuxDialogSpec(title: "Close tab?", buttons: [.cancel(), .ok()]), in: .tab(tab)) { _ in }
        for _ in 0..<3 {
            tab.isHidden = true
            tab.isHidden = false
        }
        // One view for the dialog's whole life, the keyboard back on each show, nothing given back early.
        #expect(drawing.attached == 1)
        #expect(drawing.focused == 4)
        #expect(drawing.detached == 0)
        center.dismiss(id)
        #expect(drawing.detached == 1)
    }
}
