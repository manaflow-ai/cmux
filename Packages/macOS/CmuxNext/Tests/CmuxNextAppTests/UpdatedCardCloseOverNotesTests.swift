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

        // The pointer comes onto the x over the popover's band. The move goes to the popover's window, the
        // window on top there, never to the sidebar's tracking areas: the popover's window recomputes the
        // sidebar's hover on it, so the card counts the pointer as on it and its x shows. (The synthesized
        // pointer is set without a refresh of its own, so only that move can light the card.)
        let windowKey = ObjectIdentifier(window)
        PointerHover.debugPointers[windowKey] = PointerHover.DebugPointer(point: window.convertPoint(fromScreen: point),
                                                                          mouse: NSEvent.mouseLocation)
        defer { PointerHover.debugPointers[windowKey] = nil }
        #expect(!host.isHovered, "setup: nothing has told the card about the pointer yet")
        let move = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: popup.convertPoint(fromScreen: point), modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popup.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        popup.sendEvent(move)
        #expect(host.isHovered, "a move over the popover's band reaches the card's hover")
        #expect(!x.isHidden, "the x shows while the pointer is on the card under the open popover")

        // A press there goes to the sidebar's window at the same point (the popover's window passes it
        // on), and the sidebar's window finds the x there; pressing it dismisses the card. (A synthesized
        // press through the x's own tracking loop would wait for a release that never comes.)
        let content = try #require(window.contentView)
        let hit = try #require(content.hitTest(window.convertPoint(fromScreen: point)))
        #expect(hit === x || hit.isDescendant(of: x), "the press under the popover's band lands on the x, not \(type(of: hit))")
        x.performClick(nil)
        #expect(intents == [.dismissUpdated], "the x under the open popover dismisses the card")
    }
}
