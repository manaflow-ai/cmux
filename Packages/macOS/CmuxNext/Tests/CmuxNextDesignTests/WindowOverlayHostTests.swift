import AppKit
@testable import CmuxNextDesign
import Testing

/// App overlays draw on one host panel per main window, above every Chromium
/// page window. The CEF fork re-adds a page window above every child each
/// time it shows; before, tooltips, in-window alerts and app panels shown
/// before such a re-add were below the page.
@MainActor
@Suite(.serialized) struct WindowOverlayHostTests {
    init() { _ = NSApplication.shared }

    /// Off screen, but ordered in: child windows are ordered only under a visible parent.
    private func makeMain() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    /// A stand-in for a Chromium page window (a child window that is not a panel).
    private func makePage() -> NSWindow {
        let page = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 500), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        return page
    }

    private func close(_ windows: NSWindow...) {
        for window in windows {
            window.childWindows?.forEach { window.removeChildWindow($0); $0.orderOut(nil) }
            window.close()
        }
    }

    // MARK: Order

    /// The fork removes a page window and adds it again above every child
    /// (a tab shown again): the host panel is above it as soon as the
    /// window's children change.
    @Test func overlayStaysAbovePageWindowsAfterAReShow() {
        let main = makeMain()
        let page = makePage()
        defer { close(main, page) }
        main.addChildWindow(page, ordered: .above)
        let host = WindowOverlayHost.host(for: main)
        let tooltip = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 24)),
                                   options: .tooltip(at: NSRect(x: 100, y: 400, width: 40, height: 20)))
        #expect(host.isPanelAttached)
        #expect(host.isAbovePages)

        // What the fork's parent tracker does on every show and re-parent.
        main.removeChildWindow(page)
        main.addChildWindow(page, ordered: .above)
        #expect(!host.isAbovePages, "the stand-in page went above the panel")
        WindowOverlayHost.childWindowsDidChange(of: main)
        #expect(host.isAbovePages, "the panel is back above the page")
        #expect(main.childWindows?.last === host.panel)

        tooltip.dismiss()
        #expect(!host.isPanelAttached, "no overlay and no planes: no panel")
    }

    // MARK: Guard

    /// Only the host panel and page windows may be children of a main
    /// window; a presenter that adds a panel of its own is caught.
    @Test func aPanelOutsideTheHostTripsTheGuard() {
        let main = makeMain()
        defer { close(main) }
        let host = WindowOverlayHost.host(for: main)
        #expect(ChildWindowPolicy.check(host.panel, parent: main))
        #expect(ChildWindowPolicy.check(makePage(), parent: main))
        #expect(!ChildWindowPolicy.check(UnlistedPresenterPanel(), parent: main))
        #expect(ChildWindowPolicy.violations.filter { $0 == "UnlistedPresenterPanel" }.count == 1)
    }

    // MARK: Mouse

    /// Tooltips never take the mouse; a popover takes it over itself; a
    /// tab-region modal blocks input only inside its rect; a dimming dialog
    /// blocks the whole window.
    @Test func inputIsBlockedOnlyWhereAnOverlayNeedsIt() {
        let main = makeMain()
        defer { close(main) }
        let host = WindowOverlayHost.host(for: main)
        let tooltip = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 20)),
                                   options: .tooltip(at: NSRect(x: 50, y: 300, width: 10, height: 10)))
        #expect(host.interactiveRegions().isEmpty)
        let popover = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)),
                                   options: OverlayOptions(kind: .popover, anchor: NSRect(x: 300, y: 400, width: 20, height: 20)))
        let center = NSPoint(x: popover.content.frame.midX, y: popover.content.frame.midY)
        #expect(host.acceptsMouse(at: center))
        #expect(!host.acceptsMouse(at: NSPoint(x: 20, y: 20)))
        let region = NSRect(x: 0, y: 0, width: 150, height: 600)
        let tabModal = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 60)),
                                    options: OverlayOptions(kind: .dialog, anchor: region, modalRegion: region))
        #expect(host.acceptsMouse(at: NSPoint(x: 20, y: 20)), "inside the tab region")
        #expect(!host.acceptsMouse(at: NSPoint(x: 600, y: 50)), "the rest of the window stays usable")
        #expect(!host.blocksWholeWindow, "dividers keep working beside a tab-region modal")
        let dialog = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200)), options: .dialog())
        #expect(host.acceptsMouse(at: NSPoint(x: 600, y: 50)), "a dimming dialog blocks the window")
        #expect(host.blocksWholeWindow, "divider catchers stand down under a dimming dialog")
        for handle in [dialog, tabModal, popover, tooltip] { handle.dismiss() }
        #expect(!host.hasPresentations)
    }

    /// A tab dialog (modal with a modalRegion) blocks only its tab: the rest
    /// of the window keeps working. A tab resize moves the blocked region
    /// with the dialog.
    @Test func aTabModalBlocksOnlyItsRegionAndFollowsIt() {
        let main = makeMain()
        defer { close(main) }
        let host = WindowOverlayHost.host(for: main)
        let tab = NSRect(x: 0, y: 0, width: 300, height: 600)
        let dialog = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)),
                                  options: OverlayOptions(kind: .dialog, anchor: tab, isModal: true, modalRegion: tab))
        #expect(host.acceptsMouse(at: NSPoint(x: 20, y: 20)), "inside the tab")
        #expect(!host.acceptsMouse(at: NSPoint(x: 600, y: 300)), "the rest of the window stays usable")
        #expect(host.wantsKey(forClickIn: host.panel, at: NSPoint(x: 20, y: 20)), "a click inside the tab gives the dialog the keyboard")
        #expect(!host.wantsKey(forClickIn: main, at: NSPoint(x: 600, y: 300)), "a click outside gives it back to the window")

        let resized = NSRect(x: 400, y: 0, width: 300, height: 600)
        dialog.update(anchor: resized, modalRegion: resized)
        #expect(host.acceptsMouse(at: NSPoint(x: 500, y: 300)), "the region moved with the tab")
        #expect(!host.acceptsMouse(at: NSPoint(x: 20, y: 20)), "the old region is free")
        #expect(dialog.content.frame.midX == resized.midX, "the dialog moved too")
        dialog.dismiss()
    }

    /// After the pointer leaves a tab dialog's region, a click outside it
    /// reaches the window even if the panel still took the mouse (no move
    /// event switched it off first).
    @Test func aClickOutsideTheRegionReachesTheWindow() {
        let main = makeMain()
        defer { close(main) }
        let target = ClickRecorder(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        main.contentView = target
        let host = WindowOverlayHost.host(for: main)
        let tab = NSRect(x: 0, y: 0, width: 300, height: 600)
        let dialog = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)),
                                  options: OverlayOptions(kind: .dialog, anchor: tab, isModal: true, modalRegion: tab))
        host.panel.ignoresMouseEvents = false
        // The window server sends the drag and the up of a click to the window that got the down: the panel.
        host.panel.sendEvent(Self.mouse(.leftMouseDown, at: NSPoint(x: 600, y: 300), in: host.panel))
        host.panel.sendEvent(Self.mouse(.leftMouseDragged, at: NSPoint(x: 610, y: 300), in: host.panel))
        host.panel.sendEvent(Self.mouse(.leftMouseUp, at: NSPoint(x: 610, y: 300), in: host.panel))
        #expect(target.events == [.leftMouseDown, .leftMouseDragged, .leftMouseUp], "the whole click went on to the window")
        #expect(host.panel.ignoresMouseEvents, "the panel let go of the mouse")
        #expect(!host.wantsKey(forClickIn: host.panel, at: NSPoint(x: 600, y: 300)))
        #expect(host.wantsKey(forClickIn: host.panel, at: NSPoint(x: 100, y: 300)))
        dialog.dismiss()
    }

    /// A forwarded click on the sidebar (an occluder) goes to the window,
    /// not to the page window whose frame runs under the sidebar.
    @Test func aForwardedClickOnTheSidebarReachesTheWindowNotThePage() {
        let main = makeMain()
        let page = makePage()
        defer { close(main, page) }
        let window = ClickRecorder(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        main.contentView = window
        let pageView = ClickRecorder(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        page.contentView = pageView
        page.setFrame(main.frame, display: false)
        main.addChildWindow(page, ordered: .above)
        let host = WindowOverlayHost.host(for: main)
        host.setOccluder(id: "sidebar", rect: NSRect(x: 0, y: 0, width: 240, height: 600))
        let tab = NSRect(x: 400, y: 0, width: 400, height: 600)
        let dialog = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)),
                                  options: OverlayOptions(kind: .dialog, anchor: tab, isModal: true, modalRegion: tab))
        host.panel.ignoresMouseEvents = false
        host.panel.sendEvent(Self.mouse(.leftMouseDown, at: NSPoint(x: 100, y: 300), in: host.panel))
        host.panel.sendEvent(Self.mouse(.leftMouseUp, at: NSPoint(x: 100, y: 300), in: host.panel))
        #expect(window.events == [.leftMouseDown, .leftMouseUp])
        #expect(pageView.events.isEmpty)
        dialog.dismiss()
        host.setOccluder(id: "sidebar", rect: nil)
    }

    /// A popover that grows after it was presented takes the mouse over its
    /// new area at once (no stale region).
    @Test func aGrowingOverlayTakesTheMouseOverItsNewArea() {
        let main = makeMain()
        defer { close(main) }
        let host = WindowOverlayHost.host(for: main)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        let popover = host.present(content, options: OverlayOptions(kind: .popover, anchor: NSRect(x: 100, y: 400, width: 20, height: 20)))
        let far = NSPoint(x: content.frame.minX + 250, y: content.frame.midY)
        #expect(!host.acceptsMouse(at: far))
        content.setFrameSize(NSSize(width: 300, height: 40))
        #expect(host.acceptsMouse(at: far), "the region follows the content's new size")
        popover.dismiss()
    }

    /// The keyboard comes back to the saved first responder when nothing
    /// else took it while the modal showed.
    @Test func dismissingAModalRestoresTheFocusItTook() {
        let main = makeMain()
        defer { close(main) }
        let before = NSTextField(frame: NSRect(x: 400, y: 10, width: 100, height: 22))
        let other = NSTextField(frame: NSRect(x: 400, y: 60, width: 100, height: 22))
        main.contentView?.addSubview(before)
        main.contentView?.addSubview(other)
        main.makeFirstResponder(before)
        let host = WindowOverlayHost.host(for: main)
        let dialog = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)), options: .dialog())
        main.makeFirstResponder(other)
        dialog.dismiss()
        #expect(Self.owner(of: main.firstResponder) === before, "the focus the modal took comes back")
    }

    /// Dismissing a tab dialog after the person moved on to another view
    /// leaves the keyboard there.
    @Test func dismissingATabDialogKeepsFocusWhereThePersonMovedIt() {
        let main = makeMain()
        defer { close(main) }
        let before = NSTextField(frame: NSRect(x: 400, y: 10, width: 100, height: 22))
        let later = NSTextField(frame: NSRect(x: 400, y: 60, width: 100, height: 22))
        main.contentView?.addSubview(before)
        main.contentView?.addSubview(later)
        main.makeFirstResponder(before)
        let host = WindowOverlayHost.host(for: main)
        let tab = NSRect(x: 0, y: 0, width: 300, height: 600)
        let dialog = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)),
                                  options: OverlayOptions(kind: .dialog, anchor: tab, isModal: true, modalRegion: tab))
        // The person clicks into the window and types there: another window takes the keyboard.
        main.makeFirstResponder(later)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: main)
        dialog.dismiss()
        #expect(Self.owner(of: main.firstResponder) === later)
    }

    // MARK: Modal

    /// A modal overlay traps focus: its first field takes the keyboard, Tab
    /// cycles inside it, Escape dismisses it, and the previous first
    /// responder comes back.
    @Test func modalOverlayTrapsFocusAndEscapeDismisses() {
        let main = makeMain()
        defer { close(main) }
        let outside = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 22))
        main.contentView?.addSubview(outside)
        main.makeFirstResponder(outside)
        let previous = main.firstResponder

        let dialog = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let first = NSTextField(frame: NSRect(x: 10, y: 70, width: 200, height: 22))
        let second = NSTextField(frame: NSRect(x: 10, y: 30, width: 200, height: 22))
        dialog.addSubview(first)
        dialog.addSubview(second)
        let host = WindowOverlayHost.host(for: main)
        var dismissed = 0
        let handle = host.present(dialog, options: .dialog())
        handle.onDismiss = { dismissed += 1 }

        #expect(host.panel.canBecomeKey, "a modal overlay may take the keyboard")
        #expect(Self.owner(of: host.panel.firstResponder) === first)
        host.panel.sendEvent(Self.key("\t", keyCode: 48, panel: host.panel))
        #expect(Self.owner(of: host.panel.firstResponder) === second)
        host.panel.sendEvent(Self.key("\t", keyCode: 48, panel: host.panel))
        #expect(Self.owner(of: host.panel.firstResponder) === first, "Tab cycles inside the overlay")

        host.panel.sendEvent(Self.key("\u{1b}", keyCode: 53, panel: host.panel))
        #expect(handle.isDismissed)
        #expect(dismissed == 1)
        #expect(!host.panel.canBecomeKey)
        #expect(main.firstResponder === previous, "the previous first responder is back")
    }

    /// Without a window (quit with every window closed) the app host shows
    /// the same overlays in a panel of its own.
    @Test func appHostPresentsWithoutAWindow() {
        let screen = WindowOverlayHost.appHostScreenFrame
        WindowOverlayHost.appHostScreenFrame = { NSRect(x: -30_000, y: -30_000, width: 1280, height: 800) }
        defer { WindowOverlayHost.appHostScreenFrame = screen }
        let host = WindowOverlayHost.appHost()
        let handle = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 140)), options: .dialog(dimsContent: false))
        #expect(host.hasPresentations)
        #expect(host.panel.frame.size == NSSize(width: 320, height: 140))
        handle.dismiss()
        #expect(!host.hasPresentations)
        #expect(!host.panel.isVisible)
    }

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                           pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// A key down as the keyboard sends it to `panel`.
    private static func key(_ characters: String, keyCode: UInt16, panel: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: panel.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    /// The field editor stands in for a text field while it edits.
    private static func owner(of responder: NSResponder?) -> NSResponder? {
        if let editor = responder as? NSTextView, editor.isFieldEditor { return editor.delegate as? NSResponder }
        return responder
    }
}

/// A presenter panel that is neither the host panel nor a listed legacy panel.
private final class UnlistedPresenterPanel: NSPanel {}

/// Counts the clicks that reach it.
private final class ClickRecorder: NSView {
    var events: [NSEvent.EventType] = []
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { events.append(.leftMouseDown) }
    override func mouseDragged(with event: NSEvent) { events.append(.leftMouseDragged) }
    override func mouseUp(with event: NSEvent) { events.append(.leftMouseUp) }
}
