import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// This Mac's Share button in the one-list sidebar's footer row (Leo, ask-0a91bcfdb0: "for screensharing, jf theres
/// no easy path to use it then theres no point even if its the most performant thing in the world"). The one-list
/// layout (the default) draws no This Mac header, so the header's Share button never shows there; the footer row
/// carries one Share button at rest, sending the header's own intent, and hides where the header shows.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarFooterShareScreenTests {
    struct Harness {
        let sidebar: SidebarView
        let window: NSWindow

        func settle() {
            sidebar.renderNow()
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
        }

        func frame(of view: NSView) -> NSRect { sidebar.convert(view.bounds, from: view) }
    }

    static func section(_ id: MachineID, name: String, kind: SidebarMachine.Kind) -> SidebarSection {
        SidebarSection(kind: .machine(SidebarMachine(id: id, name: name, kind: kind)),
                       nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("ws-" + id.rawValue), title: "A project with a long title",
                                                           directory: "~/Projects"))])
    }

    static var thisMacAndCloud: [SidebarSection] {
        [section(.local, name: "This Mac", kind: .local), section(MachineID("cloud"), name: "Cloud box", kind: .cloud)]
    }

    private func make(width: CGFloat, sections: [SidebarSection] = Self.thisMacAndCloud,
                      groupsByComputer: Bool = false) async -> Harness {
        _ = NSApplication.shared
        let model = SidebarModel(sections: sections)
        model.profileAvatar = SidebarAvatar(name: "Default", color: .blue)
        let design = DesignSettings()
        design.sidebarSections.groupsByComputer = groupsByComputer
        let sidebar = SidebarView(model: model, design: design)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        let harness = Harness(sidebar: sidebar, window: window)
        for _ in 0..<20 {
            harness.settle()
            if sidebar.footerBand.profileControl != nil { break }
            await Task.yield()
        }
        harness.settle()
        return harness
    }

    // MARK: When it shows

    @Test func onlyTheOneListLayoutWithThisMacListedOffersFooterShare() {
        let mac = Self.section(.local, name: "This Mac", kind: .local)
        let cloud = Self.section(MachineID("cloud"), name: "Cloud box", kind: .cloud)
        let ssh = Self.section(MachineID("ssh"), name: "Build box", kind: .ssh)
        #expect(SidebarView.footerShareMachine(groupsByComputer: false, sections: [cloud, mac, ssh]) == .local)
        #expect(SidebarView.footerShareMachine(groupsByComputer: true, sections: [cloud, mac, ssh]) == nil,
                "a section per computer: This Mac's header carries Share")
        #expect(SidebarView.footerShareMachine(groupsByComputer: false, sections: [cloud, ssh]) == nil,
                "a remote machine cannot share this Mac")
        #expect(SidebarView.footerShareMachine(groupsByComputer: false, sections: []) == nil)
    }

    @Test func theOneListFooterShowsShareAtRestAndItSendsThisMacsShare() async throws {
        let h = await make(width: 300)
        defer { h.window.close() }
        var intents: [SidebarIntent] = []
        h.sidebar.model.onIntent = { intents.append($0) }
        let button = h.sidebar.shareScreenButton
        #expect(!button.isHidden)
        #expect(button.alphaValue == 1, "at rest, not on hover")
        #expect(button.label == Strings.shareScreen)
        #expect(h.frame(of: button).width > 0)
        // The list draws no This Mac header to carry it.
        #expect(h.sidebar.list.rowViews[.section(SectionID.machine(.local))] == nil)
        #expect(button.accessibilityPerformPress())
        #expect(intents == [.shareScreen(.local)])
    }

    @Test func groupedByComputerTheHeaderKeepsShareAndTheFooterHasNone() async throws {
        let h = await make(width: 300, groupsByComputer: true)
        defer { h.window.close() }
        var intents: [SidebarIntent] = []
        h.sidebar.model.onIntent = { intents.append($0) }
        #expect(h.sidebar.shareScreenButton.isHidden)
        #expect(!h.sidebar.shareScreenButton.accessibilityPerformPress())
        let header = try #require(h.sidebar.list.rowViews[.section(SectionID.machine(.local))] as? SectionHeaderRowView)
        #expect(header.showsScreenButton)
        #expect(intents.isEmpty)
    }

    @Test func switchingTheLayoutMovesShareBetweenFooterAndHeader() async throws {
        let h = await make(width: 300)
        defer { h.window.close() }
        #expect(!h.sidebar.shareScreenButton.isHidden)
        h.sidebar.design.sidebarSections.groupsByComputer = true
        h.settle()
        #expect(h.sidebar.shareScreenButton.isHidden)
        h.sidebar.design.sidebarSections.groupsByComputer = false
        h.settle()
        #expect(!h.sidebar.shareScreenButton.isHidden)
    }

    @Test func noThisMacListedNoFooterShare() async throws {
        let h = await make(width: 300, sections: [Self.section(MachineID("cloud"), name: "Cloud box", kind: .cloud)])
        defer { h.window.close() }
        #expect(h.sidebar.shareScreenButton.isHidden)
    }

    @Test func noFadeHidesItWithTheFooter() async throws {
        let h = await make(width: 300)
        defer { h.window.close() }
        h.sidebar.design.sidebarSections.noFade = true
        h.settle()
        #expect(h.sidebar.shareScreenButton.isHidden)
        #expect(h.sidebar.searchButton.isHidden)
    }

    // MARK: Geometry

    /// From the trailing edge: Search, the update button, Share; Search and the update button keep the frames
    /// they have without Share, and the avatar, the spaces strip and Share never overlap.
    @Test(arguments: [240.0, 300.0, 360.0])
    func shareNeverOverlapsTheFooterRowAndMovesNoExistingControl(width: Double) async throws {
        let h = await make(width: width)
        defer { h.window.close() }
        h.sidebar.spacesPosition = .bottom
        h.sidebar.model.profiles = [SidebarProfile(id: ProfileKey("work"), name: "Work", color: .blue),
                                    SidebarProfile(id: ProfileKey("home"), name: "Home", color: .green)]
        h.sidebar.model.activeProfileID = ProfileKey("work")
        h.sidebar.showUpdateAvailable("Update Available")
        h.settle()
        let share = h.frame(of: h.sidebar.shareScreenButton)
        let update = h.frame(of: h.sidebar.updateAvailableButton)
        let search = h.frame(of: h.sidebar.searchButton)
        let avatar = try #require(h.sidebar.footerBand.bandFirstRow?.frame)
        let bar = h.frame(of: h.sidebar.profileBar)
        #expect(!h.sidebar.shareScreenButton.isHidden && share.width > 0, "Share shows at \(width)")
        #expect(share.minX >= 0 && share.maxX <= h.sidebar.bounds.width)
        #expect(abs(share.midY - search.midY) <= 1.5, "on the footer line: \(share) \(search)")
        #expect(share.minX >= avatar.maxX, "after the avatar \(avatar): \(share)")
        #expect(share.maxX <= update.minX && update.maxX <= search.minX, "from the trailing edge: Search, update, Share")
        for other in [update, search, avatar] { #expect(!share.intersects(other)) }
        #expect(bar.maxX <= share.minX + 0.5, "the spaces strip ends before Share: \(bar) \(share)")
        for slot in h.sidebar.profileBar.slotRects() {
            let rect = h.sidebar.convert(slot, from: h.sidebar.profileBar)
            #expect(rect.maxX <= share.minX + 0.5, "space slot \(rect) before Share \(share)")
        }
        // Without Share (a section per computer) the update button and Search hold the same frames.
        h.sidebar.design.sidebarSections.groupsByComputer = true
        h.settle()
        #expect(h.sidebar.shareScreenButton.isHidden)
        #expect(h.frame(of: h.sidebar.updateAvailableButton) == update)
        #expect(h.frame(of: h.sidebar.searchButton) == search)
    }
}
