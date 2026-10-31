@testable import CmuxNextSidebar
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextResources
import AppKit
import Testing

@MainActor
private final class HoverInteractionBody: NSView, HoverCardInteractiveBody {
    var keys: [UInt16] = []
    func acceptsHoverCardMouse(at screenPoint: CGPoint, in panel: NSWindow) -> Bool { true }
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
    let target: HoverTarget
    let anchor: CGRect

    init(window: NSWindow, body: HoverInteractionBody, anchor: CGRect) {
        self.window = window
        self.body = body
        self.target = HoverTarget(id: HoverTargetID("ws:workspace"), window: window.windowNumber, delay: .zero,
                                  leave: .hides(reshow: .milliseconds(300)))
        self.anchor = anchor
    }

    var hoverCardWindow: NSWindow? { window }
    func hoverCardHit(at point: CGPoint) -> HoverCardHit? {
        anchor.contains(point) ? HoverCardHit(target: target, anchor: anchor) : nil
    }
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
    @Test func clickingAnInactiveWorkspaceTabSendsBothIDsAndKeepsRichContent() throws {
        _ = NSApplication.shared
        let target = WorkspaceID("background")
        var workspace = SidebarWorkspace(id: target, title: "Background workspace", directory: "~/project", branch: "feature")
        workspace.workspaceDescription = "Keep the existing workspace description"
        workspace.tabs = [SidebarTab(id: TabID("shell"), title: "Shell"), SidebarTab(id: TabID("review"), title: "Review")]
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [.workspace(workspace)])],
                                 activeWorkspaceID: WorkspaceID("foreground"))
        var selected: (WorkspaceID, TabID)?
        model.onIntent = { if case let .selectTab(workspace, tab) = $0 { selected = (workspace, tab) } }
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { list.hoverCards.dismiss(.action); window.contentView = nil; window.close() }
        window.contentView = list
        list.reload(animated: false)
        let card = try #require(list.hoverCard.hoverCardBody(for: WorkspaceHoverCardController.targetID(target))?.view as? WorkspaceHoverCardView)
        card.detailsToggle.performClick(nil)
        #expect(card.lines.contains { $0.contains("Keep the existing workspace description") })
        #expect(card.lines.contains { $0.contains("Review") })
        window.contentView = card
        card.frame = NSRect(x: 0, y: 0, width: 360, height: 600)
        card.layoutSubtreeIfNeeded()
        let scroll = try #require(card.tabList.subviews.first?.subviews.compactMap { $0 as? NSScrollView }.first)
        let row = try #require(scroll.documentView?.subviews.last)
        let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 1,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        row.mouseDown(with: down)
        #expect(selected == nil)
        row.mouseUp(with: up)
        #expect(selected?.0 == target)
        #expect(selected?.1 == TabID("review"))
    }

    @Test func cardStartsWithTabsAndCollapsedDetailsThenToggleRevealsDetails() throws {
        let card = WorkspaceHoverCardView()
        card.configure(WorkspaceHoverCardContent(title: "Project", icon: .terminal,
                       facts: [.init(icon: .folder, text: "Keep this detail", kind: "folder")]))
        card.tabList.configure(title: "project", tabs: [SidebarTab(id: TabID("tab"), title: "Tab")])
        #expect(card.lines.contains { $0.hasPrefix("Tab") })
        #expect(!card.lines.contains("Keep this detail"))
        #expect(!card.isDetailsExpanded)
        card.detailsToggle.performClick(nil)
        #expect(card.isDetailsExpanded)
        #expect(card.lines.contains("Keep this detail"))
    }

    @Test func aCardWithoutDetailsHasNoDisclosure() {
        let card = WorkspaceHoverCardView()
        card.configure(WorkspaceHoverCardContent(title: "Scratch", icon: .terminal, facts: []))
        #expect(card.detailsToggle.isHidden)
        card.configure(WorkspaceHoverCardContent(title: "Scratch", icon: .terminal, age: "1m", facts: []))
        #expect(!card.detailsToggle.isHidden)
        card.detailsToggle.performClick(nil)
        #expect(card.lines.contains("Scratch 1m"))
    }

    @Test func resourceSamplingRunsOnlyWhileDetailsAreExpanded() throws {
        let workspace = SidebarWorkspace(id: WorkspaceID("project"), title: "Project", directory: "~/project")
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let list = SidebarListView(model: SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [.workspace(workspace)])]))
        list.reload(animated: false)
        let source = MockResourceSource(tabs: [])
        list.hoverCard.resources.setSource(source)
        let id = WorkspaceHoverCardController.targetID(workspace.id)
        let body = try #require(list.hoverCard.hoverCardBody(for: id)?.view as? WorkspaceHoverCardView)
        defer { list.hoverCard.hoverCardDeactivated(id) }
        list.hoverCard.hoverCardActivated(id)
        #expect(!list.hoverCard.resources.isOpen)
        body.detailsToggle.performClick(nil)
        #expect(list.hoverCard.resources.isOpen)
        body.detailsToggle.performClick(nil)
        #expect(!list.hoverCard.resources.isOpen)
        #expect(!list.hoverCard.resources.isScheduled)
    }

    @Test func overflowExpandsWithoutRemovingDetailsAndResetsForAnotherWorkspace() throws {
        let card = WorkspaceHoverCardView()
        card.configure(WorkspaceHoverCardContent(title: "Project", icon: .terminal,
                       facts: [.init(icon: .folder, text: "Keep this detail", kind: "folder")]))
        let tabs = (1...7).map { SidebarTab(id: TabID("tab-\($0)"), title: "Tab \($0)") }
        card.tabList.configure(title: "project", tabs: tabs)
        #expect(card.tabList.reportedLines.count == 5)
        let more = try #require(card.tabList.subviews.first?.subviews.compactMap { $0 as? NSButton }.first)
        more.performClick(nil)
        #expect(card.tabList.reportedLines.count == 7)
        card.detailsToggle.performClick(nil)
        #expect(card.lines.contains("Keep this detail"))
        card.tabList.configure(title: "other-workspace", tabs: tabs)
        #expect(card.tabList.reportedLines.count == 5)
    }

    @Test func overflowMoreControlIsAnInteractiveHoverCardTarget() throws {
        let view = WorkspaceTabHoverCardView(rowLimit: 1)
        view.configure(title: "project", tabs: (1...3).map { SidebarTab(id: TabID("tab-\($0)"), title: "Tab \($0)") })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.contentView = nil; window.close() }
        window.contentView = view
        view.frame = window.contentView?.bounds ?? .zero
        view.layoutSubtreeIfNeeded()
        let more = try #require(view.subviews.first?.subviews.compactMap { $0 as? NSButton }.first)
        let screenPoint = window.convertPoint(toScreen: more.convert(NSPoint(x: more.bounds.midX, y: more.bounds.midY), to: nil))
        #expect(view.acceptsHoverCardMouse(at: screenPoint, in: window))
    }

    @Test func hostedCardAcceptsRowsAndOverflowAtTheirRealOrigins() throws {
        let card = WorkspaceHoverCardView()
        card.configure(WorkspaceHoverCardContent(title: "Project", icon: .terminal, facts: []))
        card.tabList.configure(title: "project", tabs: (1...6).map {
            SidebarTab(id: TabID("tab-\($0)"), title: "Tab \($0)")
        })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 300))
        card.frame = NSRect(x: 18, y: 24, width: 280, height: 240)
        window.contentView?.addSubview(card)
        card.layoutSubtreeIfNeeded()
        card.tabList.layoutSubtreeIfNeeded()

        let rows = Self.descendants(of: card.tabList).compactMap { $0 as? WorkspaceTabHoverCardRow }
            .filter { !$0.isHidden }
        #expect(rows.count == 4)
        for row in [rows.first, rows.last].compactMap({ $0 }) {
            let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
            let screenPoint = window.convertPoint(toScreen: point)
            #expect(card.acceptsHoverCardMouse(at: screenPoint, in: window))
        }
        let more = try #require(Self.descendants(of: card.tabList).compactMap { $0 as? NSButton }
            .first { !$0.isHidden && $0.title.localizedCaseInsensitiveContains("more") })
        let point = more.convert(NSPoint(x: more.bounds.midX, y: more.bounds.midY), to: nil)
        #expect(card.acceptsHoverCardMouse(at: window.convertPoint(toScreen: point), in: window))
    }

    /// `NSView.hitTest(_:)` takes a point in the receiver's superview space, so the tab list (below
    /// the title in the card's stack) converts the click into its superview. A one-tab card's only
    /// row and the details toggle take the click; the title above them does not.
    @Test func hostedOneTabCardAcceptsItsRowAndToggleButNotItsTitle() throws {
        let card = WorkspaceHoverCardView()
        card.configure(WorkspaceHoverCardContent(title: "Project", icon: .terminal,
                                                 facts: [.init(icon: .folder, text: "docs", kind: "folder")]))
        card.tabList.configure(title: "project", tabs: [SidebarTab(id: TabID("only"), title: "shell", folder: "~")])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 300))
        card.frame = NSRect(x: 18, y: 24, width: 280, height: 240)
        window.contentView?.addSubview(card)
        card.layoutSubtreeIfNeeded()
        card.tabList.layoutSubtreeIfNeeded()
        func screenPoint(of view: NSView) -> CGPoint {
            window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        }

        let row = try #require(Self.descendants(of: card.tabList).compactMap { $0 as? WorkspaceTabHoverCardRow }
            .first { !$0.isHidden })
        #expect(card.acceptsHoverCardMouse(at: screenPoint(of: row), in: window))
        #expect(!card.detailsToggle.isHidden)
        #expect(card.acceptsHoverCardMouse(at: screenPoint(of: card.detailsToggle), in: window))
        let stack = try #require(card.tabList.superview as? NSStackView)
        let title = try #require(stack.arrangedSubviews.first { !$0.isHidden })
        #expect(title !== card.tabList)
        #expect(!card.acceptsHoverCardMouse(at: screenPoint(of: title), in: window))
    }

    @Test func rowsReportTabDetailsAndReturnFocusesTheSelectedTab() throws {
        let view = WorkspaceTabHoverCardView()
        var selected: TabID?
        view.onSelect = { selected = $0 }
        view.configure(title: "app", tabs: [
            SidebarTab(id: TabID("shell"), title: "app", kind: .terminal, folder: "~", state: .success),
            SidebarTab(id: TabID("claude"), title: "Claude Code", kind: .agentChat, folder: "~/Projects/cmux", state: .working),
        ])

        #expect(view.reportedLines == ["app · ~ · Done", "Claude Code · ~/Projects/cmux · Working"])
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                 windowNumber: 0, context: nil, characters: "\u{F701}",
                                                 charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                  windowNumber: 0, context: nil, characters: "\r",
                                                  charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(!view.handleHoverCardKeyDown(enter), "Return must pass through before an arrow shows keyboard selection")
        #expect(selected == nil)
        #expect(view.handleHoverCardKeyDown(down))
        #expect(view.handleHoverCardKeyDown(enter))
        #expect(selected == TabID("claude"))
    }

    @Test func aSingleTabStillProducesAUsefulCard() {
        let view = WorkspaceTabHoverCardView()
        view.configure(title: "scratch", tabs: [
            SidebarTab(id: TabID("shell"), title: "shell", folder: "~", state: .idle),
        ])
        #expect(view.reportedLines == ["shell · ~ · Done"])
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

    @Test func aPressedRowCannotSelectAReusedRowAfterItsTabChanges() throws {
        let view = WorkspaceTabHoverCardView()
        var selected: TabID?
        view.onSelect = { selected = $0 }
        view.configure(title: "app", tabs: [
            SidebarTab(id: TabID("first"), title: "first"),
            SidebarTab(id: TabID("second"), title: "second"),
        ])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        view.layoutSubtreeIfNeeded()
        let row = try #require(view.subviews.first?.subviews.compactMap { $0 as? NSScrollView }.first?.documentView?.subviews.first)
        let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                   clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 1,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 2,
                                                 clickCount: 1, pressure: 0))
        row.mouseDown(with: down)
        view.configure(title: "app", tabs: [SidebarTab(id: TabID("second"), title: "second")])
        row.mouseUp(with: up)
        #expect(selected == nil, "a release from a stale press selected the replacement tab")
    }

    @Test func aPressedRowSurvivesARefreshForTheSameTab() throws {
        let view = WorkspaceTabHoverCardView()
        var selected: TabID?
        view.onSelect = { selected = $0 }
        let tabs = [SidebarTab(id: TabID("first"), title: "first"), SidebarTab(id: TabID("second"), title: "second")]
        view.configure(title: "app", tabs: tabs)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        view.layoutSubtreeIfNeeded()
        let row = try #require(view.subviews.first?.subviews.compactMap { $0 as? NSScrollView }.first?.documentView?.subviews.first)
        let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                   clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 1,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 2,
                                                 clickCount: 1, pressure: 0))
        row.mouseDown(with: down)
        view.configure(title: "app", tabs: tabs)
        row.mouseUp(with: up)
        #expect(selected == TabID("first"))
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
        let row = try #require(view.subviews.first?.subviews.compactMap { $0 as? NSScrollView }.first?.documentView?.subviews.first)
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

    /// Needs a real window number for the key event's window; a fleet worker at the login window has none.
    @Test(.enabled("this host puts windows on screen") { await MaskedScreenshotTests.hostShowsWindows() })
    func interactiveCardPassesKeysThroughWhilePointerStaysOnWorkspaceRow() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        try #require(window.isVisible, "the source window was not visible")
        try #require(window.windowNumber > 0, "the source window has no window number")
        let body = HoverInteractionBody()
        let row = window.convertToScreen(NSRect(x: 12, y: 72, width: 120, height: 36))
        let source = HoverInteractionSource(window: window, body: body, anchor: row)
        let coordinator = HoverCardCoordinator()
        coordinator.appIsActive = { true }
        coordinator.hoverCardsEnabled = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.windowNumberAt = { [weak window] _ in window?.windowNumber }
        coordinator.pointerLocation = { row.origin }
        coordinator.register(source)
        coordinator.pointerMoved(to: row.origin)
        try #require(coordinator.machine.shownTarget?.id == source.target.id, "the visible row did not produce its hover target")
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: row.origin, modifierFlags: [], timestamp: 1,
                                                  windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
                                                  charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        try #require(event.window === window, "the key event was not associated with the visible source window")
        #expect(coordinator.handleMonitoredEvent(event) != nil, "the row key was consumed by the card")
        #expect(body.keys.isEmpty)
        #expect(coordinator.machine.shownTarget == nil, "the row key did not dismiss the card")
        try await WorkspaceHoverCardScrollTests.tearDown(window, coordinator)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { Self.descendants(of: $0) }
    }
}
