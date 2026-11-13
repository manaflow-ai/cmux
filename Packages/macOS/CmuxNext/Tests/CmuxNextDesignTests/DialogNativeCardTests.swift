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

    /// The card keeps its padding under the buttons as above the title: a horizontal stack aligned to the top
    /// drops its bottom inset, which left the buttons on the card's bottom edge in the first After capture.
    @Test func theCardKeepsItsPaddingOnEverySide() throws {
        let center = Self.center()
        let window = Self.window()
        defer { window.close() }
        let id = center.present(CmuxDialogSpec(title: "Save changes?", lines: ["Your changes are lost."],
                                               buttons: [.cancel(), .ok()]), in: .window(window)) { _ in }
        defer { center.dismiss(id) }
        let root = try #require(center.dialog(id)?.view)
        root.layoutSubtreeIfNeeded()
        let card = try #require(Self.all(root).first { $0 is CmuxDialogView })
        let padding = CmuxDialogMetrics.cardPadding
        let inner = card.bounds.insetBy(dx: padding - 0.5, dy: padding - 0.5)
        for button in Self.all(card).compactMap({ $0 as? CmuxDialogButtonView }) {
            let frame = button.convert(button.bounds, to: card)
            #expect(inner.contains(frame), "button \(button.button.id) at \(frame) is outside the card's padding \(inner)")
        }
    }

    /// A long message scrolls in a bounded box (#37778), and the box ends partway through a line, so the person
    /// sees there is more: a box that ends on a line's edge reads as the whole list (24 workspaces, 11 shown).
    @Test func aLongMessageEndsPartwayThroughALineSoItReadsAsScrolling() throws {
        let center = Self.center()
        let window = Self.window()
        defer { window.close() }
        let lines = ["These workspaces come from the file you picked:"] + (1...24).map { "• project-\($0)" }
        let id = center.present(CmuxDialogSpec(title: "Import 24 Workspaces?", lines: lines, buttons: [.cancel(), .ok()]),
                                in: .window(window)) { _ in }
        defer { center.dismiss(id) }
        let root = try #require(center.dialog(id)?.view)
        root.layoutSubtreeIfNeeded()
        let scroll = try #require(Self.all(root).first { $0 is NSScrollView } as? NSScrollView)
        let clip = scroll.contentView
        let shown = clip.bounds
        let labels = Self.all(try #require(scroll.documentView)).compactMap { $0 as? ChromeLabel }
        #expect(labels.count == lines.count)
        // Only the vertical edges count: a legacy scroller makes the clip narrower than each line.
        func visible(_ label: ChromeLabel) -> CGFloat {
            let frame = label.convert(label.bounds, to: clip)
            return max(min(frame.maxY, shown.maxY) - max(frame.minY, shown.minY), 0)
        }
        let cut = labels.filter { visible($0) > 0.5 && visible($0) < $0.bounds.height - 0.5 }
        #expect(cut.count == 1, "no line is cut at the box's edge \(shown)")
        if let line = cut.first {
            #expect(visible(line) >= line.bounds.height * 0.3 && visible(line) <= line.bounds.height * 0.7)
        }
    }
}
