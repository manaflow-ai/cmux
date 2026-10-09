import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// cx-i3ra (nxdog77-v1): a click on a space chip in the strip did not
/// switch spaces while `space.next` did. A click on a chip reaches the
/// strip (nothing above it in the footer row takes it), and it works in a
/// window that is not key, like every other sidebar control: the first
/// click on a backgrounded window switches the space instead of only
/// activating the window.
@MainActor @Suite(.serialized) struct SpaceChipClickTests {
    private func sidebar(spaces: Int, width: CGFloat) -> (SidebarView, NSWindow) {
        let model = SidebarModel()
        model.profiles = (0..<spaces).map { SidebarProfile(id: ProfileKey("s\($0)"), name: "Space \($0)") }
        model.activeProfileID = ProfileKey("s0")
        var info = SidebarBuiltIn.account.defaultInfo
        info.avatar = SidebarAvatar(name: "Work", color: nil)
        info.title = "Work"
        model.itemInfo = [LayoutItemID("itm_account"): info]
        let view = SidebarView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.layout()
        let design = DesignSettings.shared
        let speed = design.animationSpeed
        design.animationSpeed = .off
        view.setChromeRevealed(true)
        design.animationSpeed = speed
        return (view, window)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func aChipClickInAWindowThatIsNotKeySwitchesTheSpace() throws {
        let (view, window) = sidebar(spaces: 3, width: 260)
        defer { window.close() }
        let frames = view.shortcutHintSpaceFrames
        #expect(frames.count == 3)
        let chip = try #require(frames.last)
        let point = view.convert(NSPoint(x: chip.midX, y: chip.midY), to: nil)
        let hit = try #require(view.hitTest(view.superview?.convert(point, from: nil) ?? point), "nothing under the chip")
        #expect(hit === view.profileBar, "the chip click reaches the strip, not \(type(of: hit))")
        #expect(!window.isKeyWindow)
        let down = try mouse(.leftMouseDown, at: point, in: window)
        #expect(hit.acceptsFirstMouse(for: down), "the first click on a background window switches the space")
        window.sendEvent(down)
        window.sendEvent(try mouse(.leftMouseUp, at: point, in: window))
        #expect(view.model.activeProfileID == ProfileKey("s2"), "now \(String(describing: view.model.activeProfileID))")
    }
}
