import AppKit
import Testing
@testable import CmuxNextTabs

/// A working agent's tab keeps its brand mark and shows a small spinner on it (R79);
/// other busy tabs keep the spinner in the icon's place.
@MainActor @Suite struct TabAgentMarkBusyTests {
    @Test func busyAgentTabKeepsItsMarkWithASmallSpinner() throws {
        let tabs = [
            TabItem(id: TabID("t0"), title: "Shell"),
            TabItem(id: TabID("agent"), title: "Claude", icon: .agentMark("claude"), isBusy: true),
            TabItem(id: TabID("plain"), title: "Build", icon: .symbol("terminal"), isBusy: true),
        ]
        let model = TabStripModel(tabs: tabs, selectedID: TabID("t0"))
        let strip = TabStripView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        strip.frame = NSRect(x: 0, y: 0, width: 1200, height: TabStripView.preferredHeight)
        window.contentView.addSubview(strip)
        strip.layoutSubtreeIfNeeded()
        strip.sync(fromModel: true)
        strip.layoutSubtreeIfNeeded()

        let agent = try #require(strip.cells[TabID("agent")])
        agent.layoutLayers()
        let agentSpinner = try #require(agent.spinnerLayer)
        #expect(agent.iconLayer.opacity == 1, "the mark stays visible while the agent works")
        #expect(agentSpinner.frame.width <= agent.iconLayer.frame.width * 0.7, "the spinner is a small badge on the mark")
        #expect(agentSpinner.frame.maxX >= agent.iconLayer.frame.maxX - 1 && agentSpinner.frame.minX > agent.iconLayer.frame.midX,
                "the spinner sits at the mark's trailing corner")

        let plain = try #require(strip.cells[TabID("plain")])
        plain.layoutLayers()
        #expect(plain.spinnerLayer != nil)
        #expect(plain.iconLayer.opacity == 0, "a busy symbol tab shows the spinner instead of its icon")
        window.close()
    }
}
