import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// A remote tab's machine badge keeps today's quiet look (textTertiary) until the person picks a
/// color for that machine (`appearance.machineColors`); then it draws the pick. Read from the strip
/// as drawn (the badge layer's text color).
@MainActor @Suite(.serialized, .closesItsWindows) struct TabMachineBadgeColorTests {
    /// The badge's color and textTertiary, both in the cell's theme scope, sRGB.
    static func badge(picks: MachineColorOverrides) throws -> (badge: NSColor, tertiary: NSColor) {
        ThemeScope.app.store.setMachineColors(picks)
        defer { ThemeScope.app.store.setMachineColors(.none) }
        let item = TabItem(id: TabID("remote"), title: "Remote", machineBadge: "big-red")
        let strip = TabStripView(model: TabStripModel(tabs: [item], selectedID: item.id))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        let cell = try #require(strip.cells[item.id])
        let drawn = try #require(cell.machineLayer?.foregroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        let tertiary = try #require(NSColor(cgColor: cell.themeScope.perform { Palette.textTertiary.cgColor })?.usingColorSpace(.sRGB))
        return (drawn, tertiary)
    }

    static func same(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) < 0.01 && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01 && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.01
    }

    @Test func withNoPickTheBadgeStaysTertiary() throws {
        let (badge, tertiary) = try Self.badge(picks: .none)
        #expect(Self.same(badge, tertiary), "badge \(badge), textTertiary \(tertiary)")
    }

    @Test func aPickForAnotherMachineLeavesItTertiary() throws {
        let (badge, tertiary) = try Self.badge(picks: MachineColorOverrides(["build-mac": "#12ab34"]))
        #expect(Self.same(badge, tertiary), "badge \(badge), textTertiary \(tertiary)")
    }

    @Test func withAPickTheBadgeDrawsIt() throws {
        let (badge, _) = try Self.badge(picks: MachineColorOverrides(["Big-Red": "#12ab34"]))
        let picked = try #require(ThemeRGB(cssHex: "#12ab34")?.nsColor.usingColorSpace(.sRGB))
        #expect(Self.same(badge, picked), "badge \(badge), pick \(picked)")
    }
}
