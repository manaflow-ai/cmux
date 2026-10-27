import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// A dialog shows a new spec in place (a device chooser's rows changed while it is open): it keeps
/// its id, its place in its scope's queue, its panel, a field's control and the keyboard, as Chrome's
/// chooser bubble updates its table rows in place (chrome/browser/ui/views/device_chooser_content_view.cc).
@MainActor
struct CmuxDialogUpdateTests {
    private static func spec(_ rows: [String], selected: String? = nil, lines: [String] = []) -> CmuxDialogSpec {
        CmuxDialogSpec(title: "Connect", lines: lines,
                       fields: [.choice(id: "device", label: nil, options: rows.map { CmuxDialogOption(label: $0, value: $0) },
                                        selected: selected)],
                       buttons: [.cancel(), CmuxDialogButton(id: "connect", title: "Connect", role: .default)], identifier: "chooser")
    }

    private static func find(_ view: NSView, id: String) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        for subview in view.subviews {
            if let match = find(subview, id: id) { return match }
        }
        return nil
    }

    /// A dialog queued behind the chooser in the same tab stays queued: the update shows in the
    /// chooser's own panel, and nothing is answered.
    @Test func anUpdateKeepsTheDialogVisibleAndItsQueuePlace() throws {
        _ = NSApplication.shared
        let host = CmuxDialogHeadlessHost()
        let center = CmuxDialogCenter(host: host)
        let tab = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var answers: [String] = []
        let chooser = center.present(Self.spec(["A", "B"]), in: .tab(tab)) { answers.append("chooser:\($0.button)") }
        let alert = center.present(CmuxDialogSpec(title: "Alert", buttons: [.ok()]), in: .tab(tab)) { answers.append("alert:\($0.button)") }
        let view = try #require(center.view(chooser))
        let popup = try #require(Self.find(view, id: "cmux.dialog.field.device") as? NSPopUpButton)

        #expect(center.update(chooser, spec: Self.spec(["A", "B", "C"], selected: "C", lines: ["Searching"])))
        #expect(center.record(chooser)?.visible == true && center.record(alert)?.visible == false)
        #expect(center.records.map(\.id) == [chooser, alert])
        #expect(center.view(chooser) === view && host.shown.count == 1, "the panel stays; no new one is shown")
        #expect(Self.find(view, id: "cmux.dialog.field.device") === popup, "the field keeps its control")
        #expect(popup.itemArray.compactMap { $0.representedObject as? String } == ["A", "B", "C"])
        #expect(center.record(chooser)?.values["device"] == .text("C"))
        #expect(center.record(chooser)?.spec.lines == ["Searching"])
        #expect(answers.isEmpty)

        #expect(center.press(chooser, button: "connect"))
        #expect(answers == ["chooser:connect"] && center.record(alert)?.visible == true)
        #expect(!center.update(chooser, spec: Self.spec(["A"])), "an answered dialog has nothing to update")
    }

    /// The keyboard stays on the control with the same id across an update: a kept text field keeps
    /// its editor and caret, a rebuilt button takes the keyboard back.
    @Test func anUpdateKeepsTheKeyboard() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil }
        func named(_ lines: [String]) -> CmuxDialogSpec {
            CmuxDialogSpec(title: "Name", lines: lines, fields: [.text("name", initial: "abcd")], buttons: [.cancel(), .ok()])
        }
        let view = CmuxDialogView(spec: named([]))
        try #require(window.contentView).addSubview(view)
        let field = try #require(Self.find(view, id: "cmux.dialog.field.name") as? NSTextField)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        view.update(named(["Changed"]))
        #expect(Self.find(view, id: "cmux.dialog.field.name") === field)
        #expect(field.currentEditor() === editor && editor.selectedRange == NSRange(location: 2, length: 0))

        let cancel = try #require(view.buttonViews.first { $0.button.id == "cancel" })
        #expect(window.makeFirstResponder(cancel))
        view.update(named(["Changed again"]))
        let rebuilt = try #require(view.buttonViews.first { $0.button.id == "cancel" })
        #expect(rebuilt !== cancel && window.firstResponder === rebuilt)
    }
}
