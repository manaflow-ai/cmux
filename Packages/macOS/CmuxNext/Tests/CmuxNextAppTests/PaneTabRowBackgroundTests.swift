import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

@MainActor @Suite(.serialized, .closesItsWindows)
struct PaneTabRowBackgroundTests {
    @Test(arguments: [360, 900])
    func sharingTheRowLeavesTheChromeVisibleAndSwitchingBackRestoresTheGround(width: Int) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width), height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("chat"), title: "Chat"),
                                                                   TabItem(id: TabID("new"), title: "New Tab")]),
                                   reveal: LaunchReveal(deadline: .zero))
        pane.barPosition = .top
        window.contentView = pane
        let chat = TabRowToolsStayClickableTests.RowChat(need: 220)
        pane.show(chat)
        let ground = NSColor.red.cgColor
        pane.contentHost.restingGround = ground
        for _ in 0..<4 {
            pane.needsLayout = true
            pane.layoutSubtreeIfNeeded()
        }

        let shares = width >= 440
        #expect((pane.contentHost.frame.minY < pane.stripView.frame.maxY) == shares)
        #expect(pane.contentHost.layer?.backgroundColor == (shares ? nil : ground),
                "the content container must not paint over the chrome while it extends behind the tabs")

        let updatedGround = NSColor.blue.cgColor
        pane.contentHost.restingGround = updatedGround
        #expect(pane.contentHost.layer?.backgroundColor == (shares ? nil : updatedGround))

        pane.show(NSView())
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()
        #expect(pane.contentHost.frame.minY >= pane.stripView.frame.maxY)
        #expect(pane.contentHost.layer?.backgroundColor == updatedGround)
    }
}
