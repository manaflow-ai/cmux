import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// ``HelperWindowStack`` decides, for every stacking of a main window's helper windows, which one a pointer event at a
/// point is for: an overlay that takes the mouse, then a divider catcher, then the window over an occluder, then the
/// front page, then the window. The window server's own order does not change it (the Chromium fork orders a page that
/// shows or wakes above every other child until the overlay host orders it back).
@MainActor @Suite(.serialized, .closesItsWindows) struct HelperWindowStackTests {
    final class Catcher: NSPanel, UnderOverlayWindow {}

    /// One stacking at the test point.
    struct Stacking: CustomTestStringConvertible, Sendable {
        enum CatcherState: Sendable { case none, shown, parked }
        enum Pages: Sendable { case none, one, two }
        var dialog: Bool
        var catcher: CatcherState
        var occluder: Bool
        var pages: Pages
        /// The page orders itself above the catcher, as a waking page does.
        var pageAboveCatcher: Bool

        var testDescription: String {
            "dialog \(dialog), catcher \(catcher), occluder \(occluder), pages \(pages), page above catcher \(pageAboveCatcher)"
        }

        static var all: [Stacking] {
            var all: [Stacking] = []
            for dialog in [false, true] {
                for catcher in [CatcherState.none, .shown, .parked] {
                    for occluder in [false, true] {
                        for pages in [Pages.none, .one, .two] {
                            for above in [false, true] where !above || (pages != .none && catcher != .none) {
                                all.append(Stacking(dialog: dialog, catcher: catcher, occluder: occluder, pages: pages, pageAboveCatcher: above))
                            }
                        }
                    }
                }
            }
            return all
        }
    }

    private static func page(in window: NSWindow, frame: NSRect) -> NSWindow {
        let page = NSWindow(contentRect: window.convertToScreen(frame), styleMask: [.borderless], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        window.addChildWindow(page, ordered: .above)
        return page
    }

    @Test(arguments: Stacking.all)
    func theStackPicksTheTopLayerThePersonSees(_ stacking: Stacking) throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        let point = NSPoint(x: 450, y: 300) // window coordinates
        let screen = window.convertPoint(toScreen: point)
        var made: [NSWindow] = []
        var dialog: (CmuxDialogCenter, Int)?
        defer {
            if let (center, id) = dialog { center.dismiss(id) }
            for child in made { window.removeChildWindow(child); child.close() }
            window.close()
        }

        var pages: [NSWindow] = []
        if stacking.pages != .none { pages.append(Self.page(in: window, frame: NSRect(x: 300, y: 100, width: 400, height: 400))) }
        if stacking.pages == .two { pages.append(Self.page(in: window, frame: NSRect(x: 400, y: 200, width: 300, height: 300))) }
        made += pages
        var catcher: Catcher?
        if stacking.catcher != .none {
            let panel = Catcher(contentRect: window.convertToScreen(NSRect(x: point.x - 4, y: 0, width: 8, height: 600)),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = stacking.catcher == .parked
            window.addChildWindow(panel, ordered: .above)
            catcher = panel
            made.append(panel)
        }
        if stacking.pageAboveCatcher, let front = pages.last {
            window.removeChildWindow(front)
            window.addChildWindow(front, ordered: .above)
        }
        let host = WindowOverlayHost.host(for: window)
        if stacking.occluder { host.occluders["sidebar"] = NSRect(x: 0, y: 0, width: 600, height: 600) }
        defer { host.occluders["sidebar"] = nil }
        if stacking.dialog {
            let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(activate: {}, isAppActive: { true }))
            let spec = CmuxDialogSpec(title: "Close?", lines: [], buttons: [.cancel("Cancel")], identifier: "cmux.dialog.test")
            dialog = (center, center.present(spec, in: .window(window), completion: { _ in }))
        }

        let stack = HelperWindowStack(window: window)
        let expected: HelperWindowStack.Layer =
            if stacking.dialog { .overlay }
            else if stacking.catcher == .shown, let catcher { .catcher(catcher) }
            else if stacking.occluder { .window }
            else if let front = pages.last { .page(front) }
            else { .window }
        #expect(stack.target(atScreen: screen) == expected)

        // A helper asks only for the layers under it.
        let underOverlay: HelperWindowStack.Layer =
            if stacking.catcher == .shown, let catcher { .catcher(catcher) }
            else if stacking.occluder { .window }
            else if let front = pages.last { .page(front) }
            else { .window }
        #expect(stack.target(atScreen: screen, under: .overlay) == underOverlay)
        let underCatcher: HelperWindowStack.Layer =
            if stacking.occluder { .window } else if let front = pages.last { .page(front) } else { .window }
        #expect(stack.target(atScreen: screen, under: .catcher) == underCatcher)
        #expect(stack.window(of: stack.target(atScreen: screen, under: .catcher)) === {
            if case let .page(page) = underCatcher { return page }
            return window
        }())
    }

    /// Off every helper (outside the pages and the catcher), the window gets the event.
    @Test func offEveryHelperTheWindowGetsIt() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        let page = Self.page(in: window, frame: NSRect(x: 300, y: 100, width: 400, height: 400))
        defer { window.removeChildWindow(page); page.close(); window.close() }
        let stack = HelperWindowStack(window: window)
        #expect(stack.target(atScreen: window.convertPoint(toScreen: NSPoint(x: 100, y: 50))) == .window)
        #expect(stack.target(atScreen: window.convertPoint(toScreen: NSPoint(x: 500, y: 300))) == .page(page))
    }
}
