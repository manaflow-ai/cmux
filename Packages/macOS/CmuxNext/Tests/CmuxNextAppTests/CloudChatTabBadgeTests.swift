import AppKit
import CmuxNextIcons
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// A Cloud chat's tab says "Cloud" in the trailing muted word slot where other remote tabs show their machine's
/// name: never the lease's name ("lease-lease…", #45952), and never a cloud glyph (Leo 2026-11-22: "im not sure we
/// want the cloud icon at the left. it makes it stick out in a slight eyesore-y way"). Read from the strip as drawn.
@MainActor @Suite(.serialized, .closesItsWindows) struct CloudChatTabBadgeTests {
    static let lease = "lease-lease-7f3a9c"

    static func item(chat: Bool, cloud: Bool) -> TabItem {
        var item = TabItem(id: TabID("t"), title: "Fix the login flow")
        item.setMachineBadge(lease, name: lease, cloudChat: chat && cloud)
        return item
    }

    static func cell(_ item: TabItem) throws -> (TabCell, () -> Void) {
        let strip = TabStripView(model: TabStripModel(tabs: [item], selectedID: item.id))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        return (try #require(strip.cells[item.id]), { window.closeAfterTest() })
    }

    @Test func aCloudChatSaysCloudNotItsLease() {
        let item = Self.item(chat: true, cloud: true)
        #expect(item.machineBadgeIcon == nil)
        #expect(item.machineBadge == Strings.cloudMachineBadge)
        #expect(item.machineBadge?.contains("lease") == false)
        // The machine's color pick still colors it.
        #expect(item.machineName == Self.lease)
    }

    @Test func otherRemoteTabsKeepTheirMachineName() {
        for (chat, cloud) in [(false, true), (true, false), (false, false)] {
            let item = Self.item(chat: chat, cloud: cloud)
            #expect(item.machineBadge == Self.lease, "chat \(chat), cloud \(cloud)")
            #expect(item.machineBadgeIcon == nil, "chat \(chat), cloud \(cloud)")
        }
    }

    @Test func aLocalChatGetsNoBadge() {
        var item = TabItem(id: TabID("t"), title: "Local chat")
        item.setMachineBadge(nil, name: nil, cloudChat: true)
        #expect(item.machineBadge == nil)
        #expect(item.machineBadgeIcon == nil)
    }

    @Test func theStripDrawsCloudAsAWordAndNoGlyph() throws {
        let (cell, close) = try Self.cell(Self.item(chat: true, cloud: true))
        defer { close() }
        #expect(cell.machineIconLayer == nil, "a cloud glyph still draws")
        #expect(cell.machineLayer?.string as? String == Strings.cloudMachineBadge)
    }

    @Test func theStripStillDrawsAMachineNameAsText() throws {
        let (cell, close) = try Self.cell(Self.item(chat: false, cloud: true))
        defer { close() }
        #expect(cell.machineIconLayer == nil)
        #expect(cell.machineLayer?.string as? String == Self.lease)
    }

    /// A Cloud machine's desktop tab says Cloud too, unless it already names a machine.
    @Test func aCloudDesktopTabSaysCloud() {
        var item = TabItem(id: TabID("t"), title: "Desktop")
        item.setCloudBadgeIfUnbadged()
        #expect(item.machineBadge == Strings.cloudMachineBadge && item.machineBadgeIcon == nil)
        var named = Self.item(chat: false, cloud: true)
        named.setCloudBadgeIfUnbadged()
        #expect(named.machineBadge == Self.lease)
    }

    @Test func theCellSwapsBetweenTheLeaseAndCloud() throws {
        let item = Self.item(chat: false, cloud: true)
        let strip = TabStripView(model: TabStripModel(tabs: [item], selectedID: item.id))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        let cell = try #require(strip.cells[item.id])
        cell.update(item: Self.item(chat: true, cloud: true))
        #expect(cell.machineIconLayer == nil)
        #expect(cell.machineLayer?.string as? String == Strings.cloudMachineBadge)
        cell.update(item: Self.item(chat: false, cloud: true))
        #expect(cell.machineLayer?.string as? String == Self.lease)
    }
}
