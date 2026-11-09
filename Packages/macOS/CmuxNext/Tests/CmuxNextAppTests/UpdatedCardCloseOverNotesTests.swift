import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// https://github.com/manaflow-ai/cmux/issues/39248: the "Updated to Nightly" card could not be dismissed.
/// Resting on the card opens its changes beside the sidebar in the app's one hover card window, and that
/// window keeps a clear band around the popover (its shadow and the slide's room) that reaches over the
/// card's top right corner, where the x sits. The card's hover asks which window is on top under the
/// pointer: the popover's window was, so the card counted as left, its x hid, and there was nothing to
/// click. Where the popover's window passes clicks to the sidebar (its clear band), it passes the card's
/// hover too: the x stays shown under the open popover, and a click on it dismisses the card.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct UpdatedCardCloseOverNotesTests {
    typealias Surfaces = UpdatedCardHoverPreviewTests.FakeSurfaces

    @Test func theXStaysShownAndDismissesWhileTheChangesPopoverIsOpen() throws {
        _ = NSApplication.shared
        let surfaces = Surfaces()
        let model = SidebarModel(sections: [])
        var intents: [SidebarIntent] = []
        model.onIntent = { intents.append($0) }
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let coordinator = HoverCardCoordinator()
        sidebar.hoverCards = coordinator
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 260, height: 640), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 640)
        sidebar.updateSurfaces = surfaces
        let host = sidebar.updatedCardView
        model.updatedCard = UpdatedCardHoverPreviewTests.card
        host.configure(UpdatedCardHoverPreviewTests.card)
        try #require(host.previewMode.opensBeside, "the shipped look opens the changes beside the sidebar")
        let card = try #require(surfaces.islands.first)
        let notes = try #require(surfaces.islands.dropFirst().first, "the card parks its changes' page")
        card.report(height: 48, overlay: 0)
        notes.report(height: 320, overlay: 0)
        window.orderFront(nil)
        sidebar.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        defer {
            host.notes.hide()
            window.close()
            coordinator.cardWindow?.closeAfterTest()
        }

        host.setHovered(true)
        host.notes.show(force: true)
        let popup = try #require(coordinator.cardWindow, "the changes popover did not open")
        let popover = try #require(host.notes.frame)
        let x = host.closeButton
        let point = window.convertPoint(toScreen: x.convert(NSPoint(x: x.bounds.midX, y: x.bounds.midY), to: nil))
        #expect(popup.frame.contains(point), "setup: the popover's window \(popup.frame) does not reach the x at \(point)")
        #expect(!popover.contains(point), "setup: the popover itself covers the x")

        // The window on top over the x is the popover's: the card's hover passes it, so the x stays.
        #expect(host.hoverPassThroughWindows(at: point) == [popup.windowNumber],
                "the card counts the popover's clear band over it as the card")
        let onPopover = CGPoint(x: popover.midX, y: popover.midY)
        #expect(host.hoverPassThroughWindows(at: onPopover).isEmpty, "the popover itself still ends the card's hover")
        #expect(host.closeShown, "the x shows while the pointer is on the card under the open popover")

        // The click lands in the popover's window (it is on top there) and reaches the x.
        let location = popup.convertPoint(fromScreen: point)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popup.windowNumber,
                                                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            popup.sendEvent(event)
        }
        #expect(intents == [.dismissUpdated], "the x under the open popover dismisses the card")
    }
}
