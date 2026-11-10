import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-09 ("red dot on left feels weird", the selected row "Resize Chief sandboxes"): a colored workspace
/// without an icon drew its color as a dot before its name (`workspaceColors.indicatorStyle` `dot`, NEXT's default),
/// and the dot's slot pushed that title one icon column right of every other title. Classic's default, the color bar
/// down the row's left edge (`leftRail`), says the color without a slot.
///
/// The contract, with default settings at every density: a colored text-only workspace draws no dot before its name,
/// its title starts where an uncolored row's title starts, and its color still shows as a bar left of that title.
@MainActor @Suite(.serialized, .closesItsWindows) struct WorkspaceColorKeepsTheTitleEdgeTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let colored = WorkspaceID("ws-color-red"), plain = WorkspaceID("ws-color-plain")

    /// A red text-only workspace above an uncolored one, laid out with default sidebar settings.
    static func list() -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(SidebarWorkspace(id: colored, title: "Resize Chief sandboxes", icon: .swatch(.red), color: .red)),
            .workspace(SidebarWorkspace(id: plain, title: "Custom sidebar scripting")),
        ])])
        var preferences = SidebarSectionsPreferences()
        preferences.density = DesignSettings.shared.sidebarSections.density
        model.applyListPreferences(preferences)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        window.contentView = root
        let list = SidebarListView(model: model)
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.rowViews.values.forEach { $0.needsLayout = true; $0.layoutSubtreeIfNeeded() }
        return (list, window)
    }

    static func row(_ list: SidebarListView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        let row = try #require(list.rowViews[.workspace(id)] as? WorkspaceRowView, "no row for \(id.rawValue)")
        row.layoutSubtreeIfNeeded()
        return row
    }

    @Test(arguments: SidebarDensity.allCases)
    func aColoredRowsTitleStartsWithTheOthers(_ density: SidebarDensity) throws {
        try SidebarGroupRailAlignmentTests.with(density, .off) {
            let (list, window) = Self.list()
            defer { window.close() }
            let red = try Self.row(list, Self.colored), plain = try Self.row(list, Self.plain)
            let redX = list.convert(red.title.frame, from: red).minX, plainX = list.convert(plain.title.frame, from: plain).minX
            #expect(abs(redX - plainX) <= 0.5, "\(density): the red row's title starts at \(redX), an uncolored row's at \(plainX)")
            #expect(red.icon.isHidden || red.icon.frame.width == 0 || red.icon.alphaValue == 0,
                    "\(density): the red row draws a \(red.icon.frame.width) pt dot before its name")
        }
    }

    @Test(arguments: SidebarDensity.allCases)
    func theColorStillShowsLeftOfTheTitle(_ density: SidebarDensity) throws {
        try SidebarGroupRailAlignmentTests.with(density, .off) {
            let (list, window) = Self.list()
            defer { window.close() }
            let red = try Self.row(list, Self.colored)
            #expect(!red.colorRail.isHidden && red.colorRail.superview != nil, "\(density): the red row shows its color nowhere")
            let textX = red.title.frame.minX + WorkspaceRowView.labelInset
            #expect(red.colorRail.frame.width > 0 && red.colorRail.frame.minX >= 0, "\(density): the bar is \(red.colorRail.frame)")
            #expect(red.colorRail.frame.maxX + 2 <= textX,
                    "\(density): the bar ends at \(red.colorRail.frame.maxX), the title's text starts at \(textX)")
        }
    }
}
