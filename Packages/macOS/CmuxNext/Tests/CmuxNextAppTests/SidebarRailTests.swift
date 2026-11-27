import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The thin sidebar (`sidebar.style` = rail; Lawrence 2026-10-21: "make a minimal custom design for
/// the sidebar that is thinner and takes up virtually 0 horizontal space and is still very clean";
/// plans/cmux-next/minimal-sidebar.md). A 6 pt rail of workspace ticks; Toggle Sidebar opens the
/// full sidebar over the content.
@MainActor
struct SidebarRailTests {
    private static func mark(_ id: String, selected: Bool = false, _ state: SidebarRailMark.State = .idle) -> SidebarRailMark {
        SidebarRailMark(target: .workspace(WorkspaceID(id)), isSelected: selected, state: state)
    }

    // MARK: Layout

    @Test func ticksFollowSidebarOrderWithAGapBetweenGroups() {
        let layout = SidebarRailLayout(groups: [[Self.mark("a"), Self.mark("b", selected: true)], [], [Self.mark("c")]],
                                       top: 40, available: 600)
        #expect(layout.scale == 1)
        #expect(layout.ticks.map(\.mark.target) == ["a", "b", "c"].map { .workspace(WorkspaceID($0)) })
        let ys = layout.ticks.map(\.rect.minY)
        #expect(ys[1] - ys[0] == 6)
        // The empty group adds no gap: one group gap (8) plus the pitch.
        #expect(ys[2] - ys[1] == 14)
        #expect(layout.ticks.allSatisfy { $0.rect.maxX <= SidebarRailLayout.Metrics().railWidth })
        #expect(layout.ticks[1].rect.width > layout.ticks[0].rect.width, "the selected tick is longer")
    }

    @Test func tooManyMarksCompressIntoTheRailInsteadOfScrolling() {
        let marks = (0..<300).map { Self.mark("w\($0)") }
        let layout = SidebarRailLayout(groups: [marks], top: 0, available: 600)
        #expect(layout.ticks.count == 300)
        #expect(layout.scale < 1)
        #expect((layout.ticks.last?.rect.maxY ?? .infinity) <= 600)
        #expect(layout.ticks.allSatisfy { $0.rect.height >= 1 })
    }

    @Test func aClickNearATickFindsItAndFarFromAnyFindsNothing() {
        let layout = SidebarRailLayout(groups: [[Self.mark("a"), Self.mark("b")]], top: 10, available: 400)
        let b = layout.ticks[1]
        #expect(layout.tick(near: b.rect.midY + 2)?.mark == b.mark)
        #expect(layout.tick(near: 300) == nil)
    }

    @Test func aWorkspaceMarkShowsUnreadBeforeWorking() {
        var workspace = SidebarWorkspace(id: WorkspaceID("w"), title: "build", agentWorking: true)
        #expect(SidebarRailMark(workspace: workspace, isSelected: false).state == .working)
        workspace.unread = .dot
        #expect(SidebarRailMark(workspace: workspace, isSelected: false).state == .unread)
        workspace = SidebarWorkspace(id: WorkspaceID("w"), title: "notes")
        #expect(SidebarRailMark(workspace: workspace, isSelected: false).state == .idle)
    }

    // MARK: Width

    @Test func theRailTakesItsWidthAndOpeningShowsTheFullSidebar() {
        let model = SidebarModel()
        model.width = 260
        #expect(model.displayWidth == 260)
        model.style = .rail
        #expect(model.displayWidth == SidebarRailLayout.Metrics().railWidth)
        // The content's inset beside the rail never follows the open sidebar.
        #expect(model.contentInset == SidebarRailLayout.Metrics().railWidth)
        model.isRailOpen = true
        #expect(model.displayWidth == 260)
        #expect(model.contentInset == SidebarRailLayout.Metrics().railWidth)
        model.presentation = .hidden
        #expect(model.displayWidth == 0)
        #expect(model.contentInset == 0)
    }

    @Test func theStandardSidebarIsTheDefault() {
        #expect(SidebarSectionsPreferences.defaults.style == .standard)
        let model = SidebarModel()
        #expect(model.style == .standard)
        model.isRailOpen = true
        #expect(model.displayWidth == model.width, "the open flag means nothing to the standard sidebar")
    }

    @Test func theSidebarSettingsCarryTheStyleToTheModel() {
        let model = SidebarModel()
        var preferences = SidebarSectionsPreferences.defaults
        preferences.style = .rail
        model.applyListPreferences(preferences)
        #expect(model.style == .rail)
    }

    // MARK: The container

    @Test func theContainerIsAsWideAsTheRailAndOpensOverTheContent() {
        let model = SidebarModel()
        model.width = 260
        model.style = .rail
        let container = SidebarContainerView(model: model)
        container.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        container.restore(width: 260, presentation: .shown)
        #expect(container.widthConstraint.constant == SidebarRailLayout.Metrics().railWidth)
        #expect(container.railView.isHidden == false)
        container.revealRail()
        #expect(model.isRailOpen)
        #expect(container.targetWidth == 260)
    }
}
