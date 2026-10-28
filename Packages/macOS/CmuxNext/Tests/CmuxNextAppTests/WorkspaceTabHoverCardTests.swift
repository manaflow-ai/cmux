@testable import CmuxNextSidebar
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import AppKit
import Testing

@MainActor
private final class HoverInteractionBody: NSView, HoverCardInteractiveBody {
    var keys: [UInt16] = []
    override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 72) }
    func handleHoverCardKeyDown(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        keys.append(event.keyCode)
        return true
    }
}

@MainActor
private final class HoverInteractionSource: HoverCardSource {
    let window: NSWindow
    let body: HoverInteractionBody
    let target = HoverTarget(id: HoverTargetID("ws:workspace"), window: 1, delay: .zero)
    let anchor: CGRect

    init(window: NSWindow, body: HoverInteractionBody, anchor: CGRect) {
        self.window = window
        self.body = body
        self.anchor = anchor
    }

    var hoverCardWindow: NSWindow? { window }
    func hoverCardHit(at _: CGPoint) -> HoverCardHit? { nil }
    func hoverCardAnchor(for _: HoverTargetID) -> CGRect? { anchor }
    func hoverCardTargetFrame(for _: HoverTargetID) -> CGRect? { anchor }
    func hoverCardBody(for _: HoverTargetID) -> HoverCardBody? {
        HoverCardBody(view: body, placement: .besideRow, themeAnchor: nil, interactive: true) {}
    }
    func hoverCardActivated(_: HoverTargetID) {}
    func hoverCardDeactivated(_: HoverTargetID) {}
}

@MainActor
struct WorkspaceTabHoverCardTests {
    @Test func rowsReportTabDetailsAndReturnFocusesTheSelectedTab() throws {
        let view = WorkspaceTabHoverCardView()
        var selected: TabID?
        view.onSelect = { selected = $0 }
        view.configure(title: "app", tabs: [
            SidebarTab(id: TabID("shell"), title: "app", kind: .terminal, folder: "~", state: .success),
            SidebarTab(id: TabID("claude"), title: "Claude Code", kind: .agentChat, folder: "~/Projects/cmux", state: .working),
        ])

        #expect(view.reportedLines == ["app", "app · ~ · Done", "Claude Code · ~/Projects/cmux · Working"])
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                 windowNumber: 0, context: nil, characters: "\u{F701}",
                                                 charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        #expect(view.handleHoverCardKeyDown(down))
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                  windowNumber: 0, context: nil, characters: "\r",
                                                  charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(view.handleHoverCardKeyDown(enter))
        #expect(selected == TabID("claude"))
    }

    @Test func aSingleTabStillProducesAUsefulCard() {
        let view = WorkspaceTabHoverCardView()
        view.configure(title: "scratch", tabs: [
            SidebarTab(id: TabID("shell"), title: "shell", folder: "~", state: .idle),
        ])
        #expect(view.reportedLines == ["scratch", "shell · ~ · Done"])
    }

    @Test func modifiedArrowKeysPassThroughTheCard() throws {
        let view = WorkspaceTabHoverCardView()
        view.configure(title: "app", tabs: [SidebarTab(id: TabID("shell"), title: "shell")])
        for flags in [NSEvent.ModifierFlags.command, .control, .option, .shift] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
                                                      windowNumber: 0, context: nil, characters: "\u{F701}",
                                                      charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
            #expect(!view.handleHoverCardKeyDown(event), "modifier (flags) was consumed")
        }
    }

    @Test func tabRowActivatesOnRelease() throws {
        let view = WorkspaceTabHoverCardView()
        var selected: TabID?
        view.onSelect = { selected = $0 }
        view.configure(title: "app", tabs: [SidebarTab(id: TabID("shell"), title: "shell")])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        view.layoutSubtreeIfNeeded()
        let row = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first?.documentView?.subviews.first)
        let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                   clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 1,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 2,
                                                 clickCount: 1, pressure: 0))
        row.mouseDown(with: down)
        #expect(selected == nil, "tab activated on mouse-down")
        row.mouseUp(with: up)
        #expect(selected == TabID("shell"), "tab did not activate on mouse-up")
    }

    @Test func interactiveCardHandlesKeysWhilePointerStaysOnWorkspaceRow() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 160), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        let body = HoverInteractionBody()
        let row = window.convertToScreen(NSRect(x: 12, y: 72, width: 120, height: 36))
        let source = HoverInteractionSource(window: window, body: body, anchor: row)
        let coordinator = HoverCardCoordinator()
        coordinator.appIsActive = { true }
        coordinator.pointerLocation = { row.origin }
        coordinator.pin(source.target, from: source)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: row.origin, modifierFlags: [], timestamp: 1,
                                                  windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
                                                  charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        #expect(coordinator.handleMonitoredEvent(event) == nil, "the row key was passed through")
        #expect(body.keys == [125])
        #expect(coordinator.machine.shownTarget?.id == source.target.id)
        let card = try #require(coordinator.panel).cardFrame
        coordinator.pointerMoved(to: CGPoint(x: card.midX, y: card.midY))
        #expect(coordinator.machine.shownTarget?.id == source.target.id, "moving from row into card dismissed it")
        try await WorkspaceHoverCardScrollTests.tearDown(window, coordinator)
    }
}
