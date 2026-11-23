@testable import CmuxNextDesign
import AppKit
import CmuxNextDesignTokens
import CmuxNextTestSupport
import Testing

/// Goal sidebar-hover-instant (Leo 2026-11-01: "i need these hover previews to appear a hell of a lot faster than
/// they do now"): the first sidebar card after launch took about 50 ms more than every later one (hover-instant
/// bench 124dac12, last move to shown 105 ms on sample #0, 50-74 ms after), because that show built the card
/// window, its glass and the card body, adopted the theme and laid all of it out for the first time.
/// `HoverCardCoordinator.warm()`, run at the launch's first idle moment, makes them ahead with nothing on screen,
/// and the first show reuses them.
@MainActor @Suite(.closesItsWindows, .serialized)
struct HoverCardWarmTests {
    @MainActor
    private final class Source: HoverCardSource {
        let window: NSWindow
        let anchor: CGRect
        private(set) var body: NSTextField?
        private(set) var warmBodies = 0
        private(set) var builtBodies = 0
        init(window: NSWindow, anchor: CGRect) {
            self.window = window
            self.anchor = anchor
        }
        var hoverCardWindow: NSWindow? { window }
        func hoverCardHit(at point: CGPoint) -> HoverCardHit? { nil }
        func hoverCardAnchor(for id: HoverTargetID) -> CGRect? { anchor }
        func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? {
            let body = self.body ?? { builtBodies += 1; return NSTextField(labelWithString: "") }()
            body.stringValue = id.rawValue
            self.body = body
            return HoverCardBody(view: body, placement: .besideRow, themeAnchor: nil) {}
        }
        func hoverCardWarmBody() -> HoverCardBody? {
            guard body == nil else { return nil }
            warmBodies += 1
            return hoverCardBody(for: HoverTargetID("ws:warm"))
        }
        func hoverCardActivated(_: HoverTargetID) {}
        func hoverCardDeactivated(_: HoverTargetID) {}
    }

    @Test func theFirstCardShowsInTheWindowAndBodyMadeAheadWithNothingShownBefore() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        let source = Source(window: window, anchor: CGRect(x: 110, y: 600, width: 200, height: 28))
        let coordinator = HoverCardCoordinator()
        coordinator.appIsActive = { true }
        coordinator.register(source)
        defer { coordinator.dismiss(.action); ([coordinator.panel] + coordinator.retiring).forEach { $0?.closeAfterTest() } }

        #expect(coordinator.cardWindow == nil)
        coordinator.warm()
        let warmed = try #require(coordinator.panel)
        #expect(source.warmBodies == 1)
        // Made, holding the body, laid out at its size, with a window-server window: and not on screen.
        #expect(!warmed.isVisible)
        #expect(warmed.windowNumber > 0, "the card's window-server window is made ahead too")
        #expect(source.body?.window === warmed)
        #expect(warmed.glass.fittingSize.width > 0)
        #expect(coordinator.machine.shownTarget == nil)
        #expect(coordinator.singleCardViolations().isEmpty, "\(coordinator.singleCardViolations())")
        // A second warm makes nothing more.
        coordinator.warm()
        #expect(coordinator.panel === warmed)
        #expect(source.warmBodies == 1)

        let target = HoverTarget(id: HoverTargetID("ws:a"), window: window.windowNumber, delay: .zero,
                                 leave: .hides(reshow: .milliseconds(300)))
        autoreleasepool { coordinator.pin(target, from: source) }
        #expect(coordinator.isShowing(target.id))
        #expect(coordinator.cardWindow === warmed, "the first card made a new window")
        #expect(source.builtBodies == 1, "the first card built its body again")
        #expect(coordinator.singleCardViolations().isEmpty, "\(coordinator.singleCardViolations())")
    }

    @Test func warmBuildsOneBodyWhateverTheNumberOfWindows() throws {
        _ = NSApplication.shared
        let windows = (0..<3).map { i in
            NSWindow(contentRect: NSRect(x: 100 + CGFloat(i) * 20, y: 100, width: 900, height: 600), styleMask: [.borderless],
                     backing: .buffered, defer: false)
        }
        windows.forEach { $0.isReleasedWhenClosed = false; $0.orderFront(nil) }
        defer { windows.forEach { $0.close() } }
        let sources = windows.map { Source(window: $0, anchor: CGRect(x: 110, y: 600, width: 200, height: 28)) }
        let coordinator = HoverCardCoordinator()
        coordinator.appIsActive = { true }
        sources.forEach { coordinator.register($0) }
        defer { coordinator.dismiss(.action); ([coordinator.panel] + coordinator.retiring).forEach { $0?.closeAfterTest() } }
        coordinator.warm()
        #expect(sources.map(\.warmBodies).reduce(0, +) == 1, "\(sources.map(\.warmBodies))")
        #expect(sources.compactMap(\.body).count == 1)
    }

    @Test func warmingWhileACardShowsChangesNothing() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        let source = Source(window: window, anchor: CGRect(x: 110, y: 600, width: 200, height: 28))
        let coordinator = HoverCardCoordinator()
        coordinator.appIsActive = { true }
        coordinator.register(source)
        defer { coordinator.dismiss(.action); ([coordinator.panel] + coordinator.retiring).forEach { $0?.closeAfterTest() } }
        let target = HoverTarget(id: HoverTargetID("ws:a"), window: window.windowNumber, delay: .zero,
                                 leave: .hides(reshow: .milliseconds(300)))
        autoreleasepool { coordinator.pin(target, from: source) }
        let shown = try #require(coordinator.panel)
        coordinator.warm()
        #expect(coordinator.panel === shown)
        #expect(coordinator.isShowing(target.id))
        #expect(source.warmBodies == 0)
    }
}
