import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// `tabs.shellIconTheme` machine (Leo 2026-10-21: "AND WHERE THE F*** ARE THE ICONS FOR THE F***ING MACHINES"):
/// a shell tab draws its machine's icon in place of `>_`; every other tab keeps its own icon. Read from the strip
/// as drawn too: the leading slot holds the machine's image.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabShellIconThemeTests {
    static func shell(_ icon: TabIcon = .terminal) -> TabItem { TabItem(id: TabID("t"), title: "zsh", icon: icon) }

    @Test func machineThemeGivesAShellTabItsMachinesIcon() {
        var item = Self.shell()
        item.applyShellIconTheme(.machine, machineIcon: .symbol("laptopcomputer"))
        #expect(item.icon == .symbol("laptopcomputer"))
    }

    @Test func defaultThemeKeepsTheGlyphAndAsksForNoIcon() {
        var item = Self.shell()
        var asked = false
        item.applyShellIconTheme(.default, machineIcon: { asked = true; return .symbol("server.rack") }())
        #expect(item.icon == .terminal)
        #expect(!asked, "the default theme resolves no machine icon")
    }

    @Test func aMachineWithNoIconKeepsTheGlyph() {
        var item = Self.shell()
        item.applyShellIconTheme(.machine, machineIcon: nil)
        #expect(item.icon == .terminal)
    }

    @Test func tabsThatAreNoPlainShellKeepTheirIcons() {
        for icon in [TabIcon.agentMark("claude"), .terminalDead, .browser, .icon(.agentChat), .symbol("star.fill")] {
            var item = Self.shell(icon)
            item.applyShellIconTheme(.machine, machineIcon: .symbol("server.rack"))
            #expect(item.icon == icon, "\(icon)")
        }
    }

    @Test func machineIconPrefersTheRegistryThenCloudThenDevice() {
        let registry = TabIcon.symbol("star")
        #expect(TabItem.shellMachineIcon(registry: registry, isCloud: true, deviceSymbol: "macmini") == registry)
        #expect(TabItem.shellMachineIcon(registry: nil, isCloud: true, deviceSymbol: "macmini") == .symbol("cloud"))
        #expect(TabItem.shellMachineIcon(registry: nil, isCloud: false, deviceSymbol: "macmini") == .symbol("macmini"))
        #expect(TabItem.shellMachineIcon(registry: nil, isCloud: false, deviceSymbol: "") == nil)
        #expect(TabItem.shellMachineIcon(registry: nil, isCloud: false, deviceSymbol: nil) == nil)
    }

    @Test func aUserIconStillWinsOverTheMachine() {
        var item = Self.shell()
        item.applyShellIconTheme(.machine, machineIcon: .symbol("server.rack"))
        if let mine = TabUserIcon.shared.icon("flame.fill") { item.icon = mine }
        #expect(item.icon != .symbol("server.rack"))
    }

    @Test func theStripDrawsTheMachineIcon() throws {
        var item = Self.shell()
        item.applyShellIconTheme(.machine, machineIcon: .symbol("server.rack"))
        let strip = TabStripView(model: TabStripModel(tabs: [item], selectedID: item.id))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        let cell = try #require(strip.cells[item.id])
        #expect(cell.item.icon == .symbol("server.rack"))
        #expect(cell.iconImage(tint: .labelColor) != nil)
    }
}
