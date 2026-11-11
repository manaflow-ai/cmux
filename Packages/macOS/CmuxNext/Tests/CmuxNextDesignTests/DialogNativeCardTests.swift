import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The layer rule (plans/cmux-next/language-layers.md): a dialog is native chrome, so the overlay host draws
/// every cmux dialog with AppKit views, never a web page (#37296 moved it to the overlay page). The card keeps
/// the look Lawrence picked on 2026-11-09 ("here's a design that i like"): the icon at the left, the app's own
/// for a cmux dialog with none, never for a web page's dialog; each button's key on a keycap, Escape as "esc".
@MainActor @Suite(.closesItsWindows) struct DialogNativeCardTests {
    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

    private static func center() -> CmuxDialogCenter {
        CmuxDialogCenter(host: CmuxDialogOverlayHost(activate: {}, isAppActive: { true }))
    }

    @Test func aDialogIsDrawnByAppKitViewsNotAWebPage() throws {
        let center = Self.center()
        let window = Self.window()
        defer { window.close() }
        let id = center.present(CmuxDialogSpec(title: "Rename", fields: [.text("name")], buttons: [.cancel(), .ok()]),
                                in: .window(window)) { _ in }
        defer { center.dismiss(id) }
        let view = try #require(center.dialog(id)?.view)
        let views = Self.all(view)
        #expect(Set(views.compactMap { ($0 as? CmuxDialogButtonView)?.button.id }) == ["cancel", "ok"])
        #expect(views.contains { $0.identifier?.rawValue == "cmux.dialog.field.name" })
        #expect(!views.contains { String(describing: type(of: $0)).contains("WebView") })
    }

    @Test func aCmuxDialogLeadsWithAnIconAtTheLeftAndAWebPagesNever() throws {
        let center = Self.center()
        let window = Self.window()
        defer { window.close() }
        let ours = center.present(CmuxDialogSpec(title: "Close Workspace?", buttons: [.cancel(), .ok()]), in: .window(window)) { _ in }
        let view = try #require(center.dialog(ours)?.view)
        view.layoutSubtreeIfNeeded()
        let views = Self.all(view)
        let icon = try #require(views.first { $0 is NSImageView })
        let title = try #require(views.first { ($0 as? ChromeLabel)?.stringValue == "Close Workspace?" })
        let iconFrame = icon.convert(icon.bounds, to: view), titleFrame = title.convert(title.bounds, to: view)
        #expect(iconFrame.width > 0)
        #expect(iconFrame.maxX <= titleFrame.minX)
        center.dismiss(ours)

        let page = center.present(CmuxDialogSpec(title: "Leave site?", origin: "example.com", buttons: [.cancel(), .ok()]),
                                  in: .window(window)) { _ in }
        defer { center.dismiss(page) }
        let pageView = try #require(center.dialog(page)?.view)
        #expect(!Self.all(pageView).contains { $0 is NSImageView })
    }

    @Test func eachButtonShowsItsKeyOnAKeycapAndEscapeReadsEsc() throws {
        let center = Self.center()
        let window = Self.window()
        defer { window.close() }
        let id = center.present(CmuxDialogSpec(title: "Close tab?", buttons: [.cancel(), .ok()]), in: .window(window)) { _ in }
        defer { center.dismiss(id) }
        let views = Self.all(try #require(center.dialog(id)?.view))
        let keycap = views.first { $0.identifier?.rawValue == "cmux.dialog.keycap.cancel" }
        #expect(Self.all(try #require(keycap)).contains { ($0 as? ChromeLabel)?.stringValue == "esc" })
        #expect(CmuxDialogKeyHint.escape.glyph == "esc")
    }

    @Test func typedAndSetValuesReachTheAnswer() throws {
        let center = Self.center()
        let window = Self.window()
        defer { window.close() }
        var answer: CmuxDialogAnswer?
        let id = center.present(CmuxDialogSpec(title: "Rename", fields: [.text("name", initial: "old")], buttons: [.cancel(), .ok()]),
                                in: .window(window)) { answer = $0 }
        let views = Self.all(try #require(center.dialog(id)?.view))
        let field = try #require(views.first { $0.identifier?.rawValue == "cmux.dialog.field.name" } as? NSTextField)
        #expect(field.stringValue == "old")
        // Automation sets a value: the field shows it.
        #expect(center.setValue(.text("set"), for: "name", in: id))
        #expect(field.stringValue == "set")
        // The person types: Return answers with what they typed.
        field.stringValue = "typed"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(center.key(.return, in: id))
        #expect(answer?.button == "ok")
        #expect(answer?.values["name"] == .text("typed"))
    }
}
