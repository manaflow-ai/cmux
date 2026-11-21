import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// a102: my blue bubbles sit at a chat's right edge (20 pt in from it). While a pane slides, a chat
/// held at a size wider than the pane's clip is cut at the clip's moving edge, and the cut takes my
/// bubbles first. These drive the holds a pane runs (a keyboard resize's hold of its content area,
/// and a split or close spring's hold of an agent chat) frame by frame.
///
/// Not covered: a spring that widens an agent chat's pane gives the chat its rest width on the first
/// frame (Leo 2026-11-05: no waiting for the landing), so its right part shows as the pane grows. That
/// is the chosen design, not this bug.
@MainActor @Suite(.serialized, .closesItsWindows)
struct HeldChatKeepsItsRightEdgeTests {
    /// A keyboard resize narrows the pane from its right edge: its content area holds. Home (its
    /// chat) follows the area on every frame and ends inside it, as a terminal's host does, instead
    /// of keeping its start width with its right part cut.
    @Test func homeFollowsAKeyResizeThatNarrowsItsPane() throws {
        let (services, _) = HomeLaunchRevealTests.services()
        let home = HomeHostView(services: services, conversation: "conv_local")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = root
        defer { withExtendedLifetime(services) { window.closeAfterTest() } }
        let area = PaneContentAreaView(frame: NSRect(x: 0, y: 0, width: 800, height: 700))
        root.addSubview(area)
        home.frame = area.bounds
        home.autoresizingMask = [.width, .height]
        area.addSubview(home)
        area.layoutSubtreeIfNeeded()
        // The pane's left edge stays: the hold rides it.
        area.hold = PaneMotionHold(trailing: false, bottom: false)
        for width in stride(from: 780.0, through: 560.0, by: -20.0) {
            area.setFrameSize(NSSize(width: width, height: 700))
            area.layoutSubtreeIfNeeded()
            let shown = home.convert(home.bounds, to: area)
            #expect(shown.minX >= area.bounds.minX - 0.5 && shown.maxX <= area.bounds.maxX + 0.5,
                    "frame \(width): Home spans \(shown.minX)...\(shown.maxX) in an area showing \(area.bounds.minX)...\(area.bounds.maxX): my bubbles are cut")
            #expect(abs(home.transcript.frame.width - width) < 0.5, "frame \(width): the chat is \(home.transcript.frame.width) pt wide in a \(width) pt pane")
        }
        area.hold = nil
        area.layoutSubtreeIfNeeded()
        #expect(home.frame == area.bounds, "Home is \(home.frame) after the hold, in \(area.bounds)")
    }

    /// A pane opens beside an agent chat: the chat takes its final, narrower width on the spring's first
    /// frame and keeps it (Leo 2026-11-05: no waiting for the landing), so nothing of it is cut.
    @Test func aHeldChatInANarrowingPaneTakesItsRestWidthAtTheStart() {
        _ = NSApplication.shared
        let content = NSView()
        let host = PaneHostView(pane: "chat", content: content, holdsContentInMotion: { true })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let screen = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = screen
        defer { window.closeAfterTest() }
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 800)
        host.applyShape(padding: 8, cornerRadius: 10)
        screen.addSubview(host)
        screen.layoutSubtreeIfNeeded()
        let rest = CGRect(x: 0, y: 0, width: 500, height: 800)
        host.restSize = rest.size
        host.restOffset = .zero
        host.isOnLayoutSpring = true
        host.announceRest()
        var widths: Set<CGFloat> = []
        for width in [860.0, 780, 700, 620, 540, 501] as [CGFloat] {
            PaneHeldContentLandingTests.present(host, at: CGRect(x: 0, y: 0, width: width, height: 800), rest: rest)
            widths.insert(content.frame.width)
            #expect(content.frame.maxX <= host.clipView.bounds.maxX + 0.5, "frame \(width): the chat is cut")
        }
        #expect(widths.count == 1, "the chat laid out at \(widths.sorted()) during the spring, not once at its rest width")
    }
}
