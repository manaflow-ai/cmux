import AppKit
@testable import CmuxNextHome
import CmuxNextDesign
import Testing

/// Leo 2026-10-20: the Chief's pane gets a top-right area like a workspace's (status, subagents,
/// actions), in its pane's tab row like a chat's header tools (`PaneTabRowSharing`). The docked
/// Home's Messages view puts its tools at the row's trailing end, left of the pane's own toolbar,
/// sits under the row only while they are in it, and Channels has none.
@MainActor @Suite struct HomeDockTabRowToolsTests {
    final class Dock: HomeDockSwitchView {
        override func makeContent(for mode: HomeDockMode) -> NSView? { NSView() }
    }

    final class Tools: NSView {
        override var intrinsicContentSize: NSSize { NSSize(width: 60, height: 20) }
    }

    static func dock() -> (Dock, Tools) {
        let dock = Dock(mode: .messages)
        let tools = Tools()
        dock.rowTools = [.messages: tools]
        dock.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        dock.layoutSubtreeIfNeeded()
        return (dock, tools)
    }

    @Test func messagesReportsItsToolsAndDrawsThemInTheOfferedRow() {
        let (dock, tools) = Self.dock()
        var changes = 0
        dock.onTabRowToolsChange = { changes += 1 }
        let width = 60 + Metrics.space2
        #expect(dock.tabRowToolsWidth == width)
        #expect(dock.tabRowToolsNeed == width)
        #expect(dock.fitsTabRow(room: width * 2))
        #expect(!dock.fitsTabRow(room: width))
        #expect(tools.isHidden) // not offered the row yet
        dock.setTabRow(height: 28, trailingInset: 40)
        dock.layoutSubtreeIfNeeded()
        #expect(!tools.isHidden)
        #expect(tools.frame == NSRect(x: 400 - 40 - 60, y: 300 - 28, width: 60, height: 28)) // the top: the dock is not flipped
        #expect(dock.subviews.first?.frame == NSRect(x: 0, y: 0, width: 400, height: 272))
        dock.setTabRow(height: 0, trailingInset: 0)
        dock.layoutSubtreeIfNeeded()
        #expect(tools.isHidden)
        #expect(dock.subviews.first?.frame == dock.bounds)
        #expect(changes == 0) // the width did not change
    }

    @Test func channelsHasNoToolsAndTellsThePane() async {
        let (dock, tools) = Self.dock()
        var changes = 0
        dock.onTabRowToolsChange = { changes += 1 }
        dock.setTabRow(height: 28, trailingInset: 0)
        let enabled = DesignSettings.shared.homeChannelsEnabled
        defer { DesignSettings.shared.homeChannelsEnabled = enabled }
        DesignSettings.shared.homeChannelsEnabled = true
        dock.switchTo(.channels)
        await dock.settled()
        dock.layoutSubtreeIfNeeded()
        #expect(dock.tabRowToolsWidth == nil)
        #expect(dock.tabRowToolsNeed == 60 + Metrics.space2) // kept: whether the row fits next time
        #expect(tools.isHidden)
        #expect(changes == 1)
    }
}
