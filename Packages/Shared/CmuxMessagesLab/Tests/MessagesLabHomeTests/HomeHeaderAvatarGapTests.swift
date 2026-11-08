import AppKit
import Testing
@testable import MessagesLabHome

/// User 2026-11-05 (msg 23140, the docked Chief and Home): the header's avatar ran under the "Chief" pill. At every
/// pane width, Home's and the docked Chief's narrow one, the avatar ends clear above the pill, centered over it.
@MainActor struct HomeHeaderAvatarGapTests {
    @Test(arguments: [CGFloat(360), 620, 1200])
    func theAvatarEndsClearAboveTheNamePill(width: CGFloat) {
        let header = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: width, height: 80))
        header.title = "Chief"
        header.layoutSubtreeIfNeeded()
        header.layout()
        let avatar = header.avatar.frame, pill = header.pill.frame
        let gap = header.isFlipped ? pill.minY - avatar.maxY : avatar.minY - pill.maxY
        #expect(gap >= 3, "at \(width) pt the avatar is \(gap) pt from the pill: it crowds the pill")
        #expect(abs(avatar.midX - pill.midX) < 0.5)
        #expect(avatar.minY >= 0 && avatar.maxY <= 80)
    }
}
