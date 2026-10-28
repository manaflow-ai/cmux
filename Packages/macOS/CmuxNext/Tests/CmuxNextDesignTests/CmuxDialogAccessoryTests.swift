import AppKit
@testable import CmuxNextDesign
import Testing

@MainActor
struct CmuxDialogAccessoryTests {
    @Test func tabSkipsDisabledConnectorControls() {
        let first = NSTextField(string: "search")
        let disabled = NSTextField(string: "unavailable")
        disabled.isEnabled = false
        let last = NSTextField(string: "repository")
        let content = NSStackView(views: [first, disabled, last])
        let spec = CmuxDialogSpec(title: "Repository", buttons: [.cancel()])
        let dialog = CmuxDialogView(spec: spec, accessory: .init(view: content, controls: [first, disabled, last]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = dialog
        defer { window.close() }
        first.isEnabled = false
        dialog.focusInitial()
        #expect(last.currentEditor() === window.firstResponder)
        first.isEnabled = true
        window.makeFirstResponder(first)
        #expect(dialog.handle(.tab, modifiers: []))
        #expect(last.currentEditor() === window.firstResponder)
        #expect(dialog.handle(.tab, modifiers: [.shift]))
        #expect(first.currentEditor() === window.firstResponder)
    }
}
