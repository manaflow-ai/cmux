import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// The agent cursor's name tag is a link (user, 2026-10-20): the cursor
/// carrier still lets every click through, except on a tag, where a click
/// goes to the tag's source; the overlay panel takes the mouse there, and
/// VoiceOver sees each tag as a button.
@MainActor
struct AgentCursorTagClickTests {
    final class Tags: AgentCursorTagSource {
        var tags: [AgentCursorTagTarget] = [
            AgentCursorTagTarget(id: "s1", frame: CGRect(x: 100, y: 50, width: 120, height: 22),
                                 label: "a201 · cursor-gallery", help: "Go to cursor-gallery"),
        ]
        var pressed: [String] = []
        var hovered: [String?] = []
        func agentCursorTags() -> [AgentCursorTagTarget] { tags }
        func pressAgentCursorTag(_ id: String) { pressed.append(id) }
        func hoverAgentCursorTag(_ id: String?) { hovered.append(id) }
    }

    private func setUp() throws -> (WindowOverlayHost, AgentCursorCarrierView, Tags) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let host = WindowOverlayHost.host(for: window)
        let tags = Tags()
        host.agentCursorTags = tags
        _ = host.agentCursorLayer
        return (host, try #require(host.agentCursorCarrier), tags)
    }

    /// A y-down cursor-layer point in the carrier's own (y-up) coordinates.
    private func point(_ carrier: NSView, x: CGFloat, y: CGFloat) -> NSPoint {
        NSPoint(x: x, y: carrier.bounds.height - y)
    }

    @Test func onlyATagTakesTheMouse() throws {
        // The host holds the source weakly (the window controller owns it): keep it.
        let (_, carrier, tags) = try setUp()
        let inSuper = { (p: NSPoint) in carrier.convert(p, to: carrier.superview) }
        withExtendedLifetime(tags) {
            #expect(carrier.hitTest(inSuper(point(carrier, x: 150, y: 61))) === carrier, "on the tag")
            #expect(carrier.hitTest(inSuper(point(carrier, x: 10, y: 10))) == nil, "everywhere else the page gets the click")
            #expect(carrier.hitTest(inSuper(point(carrier, x: 99, y: 61))) == nil)
        }
    }

    @Test func aClickOnATagPressesIt() throws {
        let (_, carrier, tags) = try setUp()
        let window = try #require(carrier.window)
        let inWindow = carrier.convert(point(carrier, x: 150, y: 61), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: 0,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                         clickCount: 1, pressure: 1))
            if type == .leftMouseDown { carrier.mouseDown(with: event) } else { carrier.mouseUp(with: event) }
        }
        #expect(tags.pressed == ["s1"])
    }

    @Test func voiceOverSeesEachTagAsAButton() throws {
        let (_, carrier, tags) = try setUp()
        let children = try #require(carrier.accessibilityChildren() as? [NSAccessibilityElement])
        let button = try #require(children.first)
        #expect(children.count == 1)
        #expect(button.accessibilityRole() == .button)
        #expect(button.accessibilityLabel()?.contains("a201 · cursor-gallery") == true)
        #expect(button.accessibilityHelp() == "Go to cursor-gallery")
        #expect(button.accessibilityPerformPress())
        #expect(tags.pressed == ["s1"])
        tags.tags = []
        #expect((carrier.accessibilityChildren() ?? []).isEmpty, "a tag that went away leaves VoiceOver too")
    }

    @Test func theOverlayPanelTakesTheMouseOverATag() throws {
        let (host, carrier, tags) = try setUp()
        host.setPlanesWantPanel(true)
        #expect(carrier.window === host.panel)
        host.agentCursorTagsDidChange()
        let onTag = carrier.convert(point(carrier, x: 150, y: 61), to: nil)
        let offTag = carrier.convert(point(carrier, x: 10, y: 10), to: nil)
        #expect(host.acceptsMouse(at: onTag))
        #expect(!host.acceptsMouse(at: offTag))
        host.hoverAgentCursorTag(at: onTag)
        #expect(tags.hovered.last == "s1", "hover highlights the tag")
        host.hoverAgentCursorTag(at: offTag)
        #expect(tags.hovered.last == .some(nil))
        host.setPlanesWantPanel(false)
    }
}
