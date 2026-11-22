import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// cx-5k3r (Lawrence 2026-10-08): "center spaces in bottom; spaces should
/// show better". The spaces strip in the footer row is centered on the
/// sidebar (measured from the laid-out slot frames), never covers the
/// profile control, stays inside the sidebar with many spaces, marks the
/// current space with a filled chip, and tells VoiceOver which one is
/// current. Lawrence (same day): "by default, spaces should only be visible
/// when i hover on sidebar. same as all the other buttons".
@MainActor @Suite(.serialized) struct SpaceStripCenteringTests {
    static let account = LayoutItemID("itm_account")

    private func sidebar(spaces: Int, width: CGFloat, active: Int = 0, revealed: Bool = true) -> SidebarView {
        let model = SidebarModel()
        model.profiles = (0..<spaces).map { SidebarProfile(id: ProfileKey("s\($0)"), name: "Space \($0)") }
        model.activeProfileID = ProfileKey("s\(active)")
        var info = SidebarBuiltIn.account.defaultInfo
        info.avatar = SidebarAvatar(name: "Work", color: nil)
        info.title = "Work"
        model.itemInfo = [Self.account: info]
        let view = SidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        view.layoutSubtreeIfNeeded()
        view.layout()
        // The pointer is over the sidebar, so the strip shows (it measures
        // the strip the user sees).
        let design = DesignSettings.shared
        let speed = design.animationSpeed
        design.animationSpeed = .off
        if revealed { view.setChromeRevealed(true) }
        design.animationSpeed = speed
        return view
    }

    private func controlFrame(_ view: SidebarView) throws -> NSRect {
        view.convert(try #require(view.footerRegion.itemView(Self.account)).frame, from: view.footerRegion)
    }

    @Test(arguments: [(2, 208.0), (3, 240.0), (3, 360.0), (4, 300.0)])
    func theStripIsCenteredOnTheSidebar(_ spaces: Int, _ width: Double) throws {
        let view = sidebar(spaces: spaces, width: width)
        let frames = view.shortcutHintSpaceFrames
        #expect(frames.count == spaces)
        let union = frames.dropFirst().reduce(try #require(frames.first)) { $0.union($1) }
        #expect(abs(union.midX - view.bounds.midX) <= 0.5, "strip \(union) in a \(width) pt sidebar (middle \(view.bounds.midX))")
        let control = try controlFrame(view)
        #expect(union.minX >= control.maxX - 0.5, "the strip never covers the profile control")
    }

    @Test func manySpacesStayInsideTheSidebarAndOffTheControl() throws {
        let view = sidebar(spaces: 14, width: 208, active: 9)
        let frames = view.shortcutHintSpaceFrames
        #expect(frames.count == 14)
        let control = try controlFrame(view)
        for frame in frames {
            #expect(frame.minX >= control.maxX - 0.5 && frame.maxX <= view.bounds.maxX + 0.5, "\(frame) in \(view.bounds)")
        }
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(a.maxX <= b.minX + 0.5, "slots overlap: \(a) \(b)") }
        // The current space keeps a full slot.
        #expect(frames[9].width >= Metrics.roomDotSlot - 0.5)
    }

    /// The current space sits on a filled chip (not only a stronger dot):
    /// a view under the marks covers the current space's slot (and no other)
    /// and paints it. (The chip is a view of its own so a switch can slide
    /// it; an offscreen render of the whole bar does not composite subview
    /// layers, so each part is rendered alone.)
    @Test func theCurrentSpaceSitsOnAFilledChip() throws {
        let view = sidebar(spaces: 3, width: 260, active: 1)
        let bar = view.profileBar
        let slots = view.shortcutHintSpaceFrames.map { bar.convert($0, from: view) }
        let chips = bar.subviews.filter { !$0.isHidden && $0.frame.width < bar.bounds.width / 2 }
        let chip = try #require(chips.first, "a chip view under the marks: \(bar.subviews.map(\.frame))")
        #expect(slots[1].contains(NSPoint(x: chip.frame.midX, y: chip.frame.midY)), "on the current space: \(chip.frame) \(slots)")
        #expect(!slots[0].intersects(chip.frame) && !slots[2].intersects(chip.frame))
        #expect(bar.subviews.firstIndex(of: chip) == 0, "drawn under the marks")
        let rep = try #require(chip.bitmapImageRepForCachingDisplay(in: chip.bounds))
        chip.cacheDisplay(in: chip.bounds, to: rep)
        let alpha = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0
        #expect(alpha > 0.02, "the chip is filled: \(alpha)")
    }

    @Test func voiceOverMarksTheCurrentSpaceSelected() throws {
        let view = sidebar(spaces: 3, width: 260, active: 2)
        let children = try #require(view.profileBar.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(children.count == 4, "three spaces and New Space")
        #expect(children.map { $0.isAccessibilitySelected() } == [false, false, true, false])
        #expect(children[2].accessibilityLabel() == "Space 2, current space")
        #expect(children[0].accessibilityLabel() == "Space 0")
    }

    /// By default the strip shows only while the sidebar is hovered, with
    /// the sidebar's other hover chrome (one shared reveal state). It fades;
    /// it is never removed, so VoiceOver still reaches it.
    @Test func theStripShowsOnlyWhileTheSidebarIsHovered() throws {
        let design = DesignSettings.shared
        let saved = design.animationSpeed
        defer { design.animationSpeed = saved }
        design.animationSpeed = .off
        let view = sidebar(spaces: 3, width: 260, revealed: false)
        #expect(!view.isChromeRevealed)
        #expect(view.profileBar.alphaValue == 0, "hidden at rest")
        #expect(!view.profileBar.isHidden && view.profileBar.isAccessibilityElement())
        view.setChromeRevealed(true)
        #expect(view.profileBar.alphaValue == 1, "shown with the sidebar's hover chrome")
        #expect(view.newButton.alphaValue == 1)
        view.setChromeRevealed(false)
        #expect(view.profileBar.alphaValue == 0)
    }
}
