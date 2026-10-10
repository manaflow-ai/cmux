import AppKit
@testable import CmuxNextDesign
import Testing

/// No dialog outlives its scope (coordinator, R96): closing a tab, its pane,
/// its workspace or its window ends every dialog scoped to it with the
/// cancel answer; a tab switch (the tab view kept, out of the window) does not.
@MainActor
struct CmuxDialogLifetimeTests {
    static let spec = CmuxDialogSpec(title: "Allow?", buttons: [
        CmuxDialogButton(id: "deny", title: "Deny", role: .cancel), CmuxDialogButton(id: "allow", title: "Allow", role: .default),
    ])

    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Lets the deallocation callbacks (a main-actor hop) run.
    static func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @Test func aClosedTabCancelsItsDialog() async {
        let window = Self.window()
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        var answers: [CmuxDialogAnswer] = []
        weak var closed: NSView?
        autoreleasepool {
            let tab = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
            window.contentView?.addSubview(tab)
            closed = tab
            center.present(Self.spec, in: .tab(tab)) { answers.append($0) }
            tab.removeFromSuperview()
        }
        await Self.settle()
        #expect(closed == nil, "the dialog does not keep a closed tab alive")
        #expect(answers.map(\.button) == ["deny"])
        #expect(answers.first?.isDismissal == true)
        #expect(center.records.isEmpty)
    }

    @Test func aClosedPaneCancelsTheDialogsOfEachOfItsTabs() async {
        let window = Self.window()
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        var answers: [String] = []
        autoreleasepool {
            let pane = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            window.contentView?.addSubview(pane)
            for index in 0..<2 {
                let tab = NSView(frame: pane.bounds)
                pane.addSubview(tab)
                center.present(Self.spec, in: .tab(tab)) { answers.append("tab\(index):\($0.button)") }
                center.present(Self.spec, in: .tab(tab)) { answers.append("tab\(index)-queued:\($0.button)") }
            }
            pane.removeFromSuperview()
        }
        await Self.settle()
        #expect(answers.sorted() == ["tab0-queued:deny", "tab0:deny", "tab1-queued:deny", "tab1:deny"])
        #expect(center.records.isEmpty)
    }

    @Test func aTabSwitchKeepsTheDialog() async {
        let window = Self.window()
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        var answers: [CmuxDialogAnswer] = []
        let tab = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        window.contentView?.addSubview(tab)
        let id = center.present(Self.spec, in: .tab(tab)) { answers.append($0) }
        tab.removeFromSuperview()
        await Self.settle()
        #expect(answers.isEmpty, "the tab view lives: the dialog waits")
        window.contentView?.addSubview(tab)
        center.press(id, button: "allow")
        #expect(answers.map(\.button) == ["allow"])
    }

    @Test func aClosedWindowCancelsItsTabAndWindowDialogs() async {
        let window = Self.window()
        let tab = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        window.contentView?.addSubview(tab)
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        var answers: [String] = []
        center.present(Self.spec, in: .tab(tab)) { answers.append("tab:\($0.button)") }
        center.present(Self.spec, in: .window(window)) { answers.append("window:\($0.button)") }
        window.close()
        await Self.settle()
        #expect(answers.sorted() == ["tab:deny", "window:deny"])
        #expect(center.records.isEmpty)
    }
}
