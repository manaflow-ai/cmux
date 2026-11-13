import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// A person's click on a dialog card's controls answers it (Aziz 2026-11-12: "Close IOS INTERNAL CI?" took no
/// click on Close, Cancel or "Don't ask again"). The click goes the way AppKit sends it: the overlay panel's own
/// dispatch (`NSWindow.sendEvent`), its hit test from the panel's content view down to the card's control.
@MainActor @Suite(.closesItsWindows) struct DialogCardClickTests {
    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

    /// The close question as `DestructiveConfirmation.spec` builds it: a check box, Cancel and a red Close.
    private static let spec = CmuxDialogSpec(
        title: "Close \u{201C}IOS INTERNAL CI\u{201D}?", lines: ["Still running: claude."],
        fields: [.check(id: "dont-ask-again", title: "Don\u{2019}t ask again", on: false)],
        buttons: [.cancel("Cancel"), CmuxDialogButton(id: "confirm", title: "Close", role: .destructive)],
        identifier: "cmux.dialog.confirmation")

    private struct Shown {
        let center: CmuxDialogCenter
        let window: NSWindow
        let id: Int
        let panel: NSWindow
        let root: NSView
    }

    private static func show(_ answer: @escaping (CmuxDialogAnswer) -> Void) throws -> Shown {
        let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(activate: {}, isAppActive: { true }))
        let window = Self.window()
        let id = center.present(spec, in: .window(window), completion: answer)
        let view = try #require(center.dialog(id)?.view)
        let panel = try #require(view.window)
        let root = try #require(panel.contentView)
        root.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        return Shown(center: center, window: window, id: id, panel: panel, root: root)
    }

    private static func control(_ id: String, in shown: Shown) throws -> NSView {
        let view = try #require(shown.center.dialog(shown.id)?.view)
        return try #require(all(view).first { $0.identifier?.rawValue == id })
    }

    /// The point in the middle of `control`, in its window's coordinates.
    private static func middle(of control: NSView) -> NSPoint {
        control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
    }

    private static func click(_ control: NSView, in panel: NSWindow) throws {
        let point = middle(of: control)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        // The button's tracking loop reads the up from the queue, as it does for a real click.
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        panel.sendEvent(try event(.leftMouseDown))
    }

    @Test func everyControlOfTheCardIsWhatAClickHits() throws {
        let shown = try Self.show { _ in }
        defer { shown.center.dismiss(shown.id); shown.window.close() }
        for id in ["cmux.dialog.button.confirm", "cmux.dialog.button.cancel", "cmux.dialog.field.dont-ask-again"] {
            let control = try Self.control(id, in: shown)
            let inWindow = Self.middle(of: control)
            let hit = shown.root.hitTest(shown.root.superview?.convert(inWindow, from: nil) ?? inWindow)
            #expect(hit.map { $0 === control || $0.isDescendant(of: control) } == true,
                    "\(id): the click hits \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
        }
    }

    @Test func aClickOnCloseAnswersClose() throws {
        var answer: CmuxDialogAnswer?
        let shown = try Self.show { answer = $0 }
        defer { shown.center.dismiss(shown.id); shown.window.close() }
        try Self.click(try Self.control("cmux.dialog.button.confirm", in: shown), in: shown.panel)
        #expect(answer?.button == "confirm")
    }

    @Test func aClickOnCancelAnswersCancel() throws {
        var answer: CmuxDialogAnswer?
        let shown = try Self.show { answer = $0 }
        defer { shown.center.dismiss(shown.id); shown.window.close() }
        try Self.click(try Self.control("cmux.dialog.button.cancel", in: shown), in: shown.panel)
        #expect(answer?.button == "cancel")
    }

    @Test func aClickOnTheCheckBoxChecksIt() throws {
        let shown = try Self.show { _ in }
        defer { shown.center.dismiss(shown.id); shown.window.close() }
        try Self.click(try Self.control("cmux.dialog.field.dont-ask-again", in: shown), in: shown.panel)
        #expect(shown.center.record(shown.id)?.values["dont-ask-again"] == .bool(true))
    }
}
