import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// A click on a dialog's button that the window server gave to a window under the overlay panel answers the dialog
/// (Aziz 2026-11-17, cmux NIGHTLY e0c3d84: "Close “Align GUI Bullet Points”? Still running: claude." took click after
/// click on Close and closed nothing). The card's Close sat over the divider between a terminal and a page, where a
/// divider catcher (a child window of the main window) takes the pointer; a page window is the same case.
///
/// `WindowOverlayHost.takeEventFromBelow` (the host's mouse monitor) hands such a press to the panel. The button the
/// press reached runs AppKit's tracking loop, which takes the release straight from the event queue, unseen by any
/// monitor and still addressed to the window under the panel, so its point is in that window's coordinates: the
/// release missed the button and the click answered nothing.
///
/// On a display host AppKit's own loop never sees a synthesized release (DialogCardClickTests), so a `Tracker` lies
/// over the card's control and tracks the press as `NSCell` does: it takes the next release from the queue and
/// clicks the control when that release lands on it. The window server queues the release before the press is
/// handled; the app dispatches a release no tracking loop took through the host, as `ShellWindow.sendEvent` does.
/// The suite runs serialized: every test shares the app's event queue.
@MainActor @Suite(.closesItsWindows, .serialized) struct OverlayPressFromBelowTests {
    /// AppKit's tracking of a press on `control`, which it covers: the next release in the queue ends the press, and
    /// it clicks `control` when it lands on it in this window's coordinates.
    final class Tracker: NSControl {
        let control: NSControl
        private(set) var presses = 0
        init(over control: NSControl) {
            self.control = control
            super.init(frame: .zero)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            presses += 1
            guard let release = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking,
                                                dequeue: true) else { return }
            let landed = release.window === window && bounds.contains(convert(release.locationInWindow, from: nil))
            if landed { control.performClick(nil) }
        }
    }

    /// The close question as `DestructiveConfirmation.spec` builds it.
    private static let spec = CmuxDialogSpec(
        title: "Close \u{201C}Align GUI Bullet Points\u{201D}?", lines: ["Still running: claude."],
        fields: [.check(id: "dont-ask-again", title: "Don\u{2019}t ask again", on: false)],
        buttons: [.cancel("Cancel"), CmuxDialogButton(id: "confirm", title: "Close", role: .destructive)],
        identifier: "cmux.dialog.confirmation")

    private struct Shown {
        let center: CmuxDialogCenter
        let window: NSWindow
        let id: Int
        let host: WindowOverlayHost
        let panel: NSWindow

        func close() {
            center.dismiss(id)
            for child in window.childWindows ?? [] where child !== panel { child.close() }
            window.close()
        }
    }

    private static func show(_ answer: @escaping (CmuxDialogAnswer) -> Void) throws -> Shown {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(activate: {}, isAppActive: { true }))
        let id = center.present(spec, in: .window(window), completion: answer)
        let view = try #require(center.dialog(id)?.view)
        let panel = try #require(view.window)
        panel.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        let host = try #require(WindowOverlayHost.existingHost(for: window))
        try #require(panel.isVisible, "the overlay panel shows the question")
        return Shown(center: center, window: window, id: id, host: host, panel: panel)
    }

    private static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

    /// A tracker over the dialog's control `id`, on the panel's content view.
    private static func tracker(over id: String, in shown: Shown) throws -> Tracker {
        let card = try #require(shown.center.dialog(shown.id)?.view)
        let control = try #require(all(card).first { $0.identifier?.rawValue == id } as? NSControl)
        let root = try #require(shown.panel.contentView)
        let tracker = Tracker(over: control)
        tracker.frame = root.convert(control.bounds, from: control)
        root.addSubview(tracker)
        return tracker
    }

    /// The middle of `tracker`, in screen coordinates.
    private static func screenPoint(of tracker: Tracker) -> NSPoint {
        let inPanel = tracker.convert(NSPoint(x: tracker.bounds.midX, y: tracker.bounds.midY), to: nil)
        return tracker.window!.convertPoint(toScreen: inPanel)
    }

    /// A divider catcher over `screen`: a small borderless child window of the main window, as `DividerMouseCatchers`
    /// makes one over a divider between a terminal and a page.
    private static func catcher(over screen: NSPoint, in window: NSWindow) -> NSWindow {
        let catcher = NSPanel(contentRect: NSRect(x: screen.x - 4, y: screen.y - 40, width: 8, height: 80),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        catcher.isReleasedWhenClosed = false
        catcher.backgroundColor = .clear
        window.addChildWindow(catcher, ordered: .above)
        catcher.orderFrontRegardless()
        return catcher
    }

    private static func event(_ type: NSEvent.EventType, at screen: NSPoint, in window: NSWindow, number: Int) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: screen), modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }

    /// A person's press at `screen`, released at `release`, that the window server gives to `source` (a window under
    /// the panel): the release is queued before the press is handled. The press goes through the host's monitor path;
    /// the release, when no tracking loop took it from the queue, is dispatched the same way.
    private static func click(at screen: NSPoint, releasedAt release: NSPoint? = nil, from source: NSWindow,
                              in shown: Shown, tracker: Tracker) throws {
        let down = try event(.leftMouseDown, at: screen, in: source, number: 9101)
        let up = try event(.leftMouseUp, at: release ?? screen, in: source, number: 9101)
        NSApp.postEvent(up, atStart: false)
        #expect(shown.host.takeEventFromBelow(down), "the press on the card goes to the overlay panel")
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true),
           !shown.host.takeEventFromBelow(queued) {
            queued.window?.sendEvent(queued)
        }
        #expect(tracker.presses == 1, "the press reaches the card's control once")
    }

    @Test func aClickOnCloseOverADividerCatcherClosesAtTheFirstClick() throws {
        var answers: [String] = []
        let shown = try Self.show { answers.append($0.button) }
        defer { shown.close() }
        let tracker = try Self.tracker(over: "cmux.dialog.button.confirm", in: shown)
        let point = Self.screenPoint(of: tracker)
        let catcher = Self.catcher(over: point, in: shown.window)
        try Self.click(at: point, from: catcher, in: shown, tracker: tracker)
        #expect(answers == ["confirm"], "one click on Close answers Close")
        #expect(shown.center.dialog(shown.id) == nil, "the question leaves")
    }

    @Test func aClickOnCancelOverADividerCatcherCancels() throws {
        var answers: [String] = []
        let shown = try Self.show { answers.append($0.button) }
        defer { shown.close() }
        let tracker = try Self.tracker(over: "cmux.dialog.button.cancel", in: shown)
        let point = Self.screenPoint(of: tracker)
        let catcher = Self.catcher(over: point, in: shown.window)
        try Self.click(at: point, from: catcher, in: shown, tracker: tracker)
        #expect(answers == ["cancel"])
    }

    @Test func aClickOnTheCheckBoxOverADividerCatcherChecksIt() throws {
        var answers: [String] = []
        let shown = try Self.show { answers.append($0.button) }
        defer { shown.close() }
        let tracker = try Self.tracker(over: "cmux.dialog.field.dont-ask-again", in: shown)
        let point = Self.screenPoint(of: tracker)
        let catcher = Self.catcher(over: point, in: shown.window)
        try Self.click(at: point, from: catcher, in: shown, tracker: tracker)
        #expect(shown.center.record(shown.id)?.values["dont-ask-again"] == .bool(true), "the check box is checked")
        #expect(answers.isEmpty, "a check box answers nothing")
    }

    @Test func aClickOnCloseThatReachedTheMainWindowCloses() throws {
        var answers: [String] = []
        let shown = try Self.show { answers.append($0.button) }
        defer { shown.close() }
        let tracker = try Self.tracker(over: "cmux.dialog.button.confirm", in: shown)
        try Self.click(at: Self.screenPoint(of: tracker), from: shown.window, in: shown, tracker: tracker)
        #expect(answers == ["confirm"])
    }

    @Test func aPressOnCloseReleasedOffTheCardAnswersNothing() throws {
        var answers: [String] = []
        let shown = try Self.show { answers.append($0.button) }
        defer { shown.close() }
        let tracker = try Self.tracker(over: "cmux.dialog.button.confirm", in: shown)
        let point = Self.screenPoint(of: tracker)
        let catcher = Self.catcher(over: point, in: shown.window)
        let away = NSPoint(x: shown.window.frame.minX + 20, y: shown.window.frame.minY + 20)
        try Self.click(at: point, releasedAt: away, from: catcher, in: shown, tracker: tracker)
        #expect(answers.isEmpty, "a press dragged off Close and released elsewhere answers nothing")
        #expect(shown.center.dialog(shown.id) != nil)
    }
}
