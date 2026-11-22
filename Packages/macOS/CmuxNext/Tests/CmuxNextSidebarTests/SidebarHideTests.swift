import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// The sidebar is either fully shown at the user's width or fully hidden
/// (zero width). There is no icons-only state.
@MainActor @Suite struct SidebarHideTests {
    private func handle(of container: SidebarContainerView) throws -> SidebarResizeHandle {
        try #require(container.subviews.compactMap { $0 as? SidebarResizeHandle }.first)
    }

    // MARK: Model

    @Test func toggleSwitchesBetweenShownAndHiddenAndKeepsTheWidth() {
        let model = SidebarModel(sections: fixture())
        model.width = 250
        #expect(model.presentation == .shown)
        #expect(model.displayWidth == 250)
        model.toggle()
        #expect(model.presentation == .hidden)
        #expect(model.isHidden)
        #expect(model.displayWidth == 0)
        #expect(model.width == 250)
        model.toggle()
        #expect(model.presentation == .shown)
        #expect(model.displayWidth == 250)
    }

    @Test func presentationChangesNotifySynchronouslyOncePerChange() {
        let model = SidebarModel()
        var seen: [SidebarPresentation] = []
        model.onPresentationChange = { seen.append($0) }
        model.presentation = .hidden
        model.presentation = .hidden
        model.toggle()
        #expect(seen == [.hidden, .shown])
    }

    // MARK: Container

    @Test func restoringHiddenCollapsesToZeroWithoutAnimatingAndHidesTheContent() throws {
        let container = SidebarContainerView(model: SidebarModel(sections: fixture()))
        container.restore(width: 230, presentation: .hidden)
        #expect(container.widthConstraint.constant == 0)
        #expect(container.model.width == 230)
        #expect(container.sidebarView.isHiddenOrHasHiddenAncestor)
        #expect(try handle(of: container).isHidden)
        container.restore(width: nil, presentation: .shown)
        #expect(container.widthConstraint.constant == 230)
        #expect(!container.sidebarView.isHiddenOrHasHiddenAncestor)
        #expect(try !handle(of: container).isHidden)
    }

    /// A window with no screen (display unplugged or asleep, a screenless
    /// host; an offscreen window here) never advances an AppKit animation,
    /// so the hide must apply at once: width 0 and the content hidden (the
    /// animation's completion). Before, the width stayed at the user's
    /// width and the content stayed shown for an indefinite time.
    @Test func hidingInAWindowWithNoScreenFinishesAtOnce() async throws {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = SidebarContainerView(model: SidebarModel(sections: fixture()))
        container.restore(width: 230, presentation: .shown)
        let content = try #require(window.contentView)
        content.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.topAnchor.constraint(equalTo: content.topAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        try #require(window.screen == nil, "the test window has no screen")
        container.model.presentation = .hidden
        // The container applies the change from its model observation.
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(5))
        func finished() -> Bool { container.widthConstraint.constant == 0 && container.sidebarView.isHiddenOrHasHiddenAncestor }
        while !finished(), clock.now < end { try await clock.sleep(for: .milliseconds(20)) } // test-only wait
        #expect(container.widthConstraint.constant == 0)
        #expect(container.sidebarView.isHiddenOrHasHiddenAncestor, "the hide's completion ran")
    }

    @Test func draggingTheEdgeResizesAboveTheThreshold() throws {
        let container = SidebarContainerView(model: SidebarModel(sections: fixture()))
        container.restore(width: 240, presentation: .shown)
        let handle = try handle(of: container)
        handle.onDrag?(.began)
        handle.onDrag?(.changed(-40))
        #expect(container.model.width == 200)
        #expect(container.widthConstraint.constant == 200)
        // Between the threshold and the minimum the width holds at the minimum.
        handle.onDrag?(.changed(SidebarContainerView.hideThreshold + 1 - 240))
        #expect(container.model.presentation == .shown)
        #expect(container.model.width == Metrics.sidebarMinWidth)
        handle.onDrag?(.ended)
    }

    @Test func draggingTheEdgeBelowTheThresholdHidesFullyAndKeepsTheStartWidth() throws {
        let container = SidebarContainerView(model: SidebarModel(sections: fixture()))
        container.restore(width: 240, presentation: .shown)
        let handle = try handle(of: container)
        handle.onDrag?(.began)
        handle.onDrag?(.changed(-120))
        handle.onDrag?(.changed(-(240 - SidebarContainerView.hideThreshold + 1)))
        #expect(container.model.presentation == .hidden)
        #expect(container.model.width == 240)
        // Dragging back in the same press does not reveal it.
        handle.onDrag?(.changed(0))
        #expect(container.model.presentation == .hidden)
        handle.onDrag?(.ended)
        container.model.toggle()
        #expect(container.model.displayWidth == 240)
    }

    @Test func renameWhileHiddenShowsTheSidebarFirst() {
        let model = SidebarModel(sections: fixture())
        let container = SidebarContainerView(model: model)
        container.restore(width: 240, presentation: .hidden)
        container.beginRename(workspace: id("a"))
        #expect(model.presentation == .shown)
        #expect(!container.sidebarView.isHiddenOrHasHiddenAncestor)
    }

    @Test func aHiddenSidebarTakesNoTabDrops() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        let model = SidebarModel(sections: fixture())
        let sidebar = SidebarView(model: model)
        sidebar.frame = window.contentView!.bounds
        window.contentView!.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        let center = window.convertPoint(toScreen: NSPoint(x: 150, y: 300))
        model.presentation = .hidden
        #expect(sidebar.tabDragUpdate(screenPoint: center, sourceMachine: .local) == nil)
    }
}
