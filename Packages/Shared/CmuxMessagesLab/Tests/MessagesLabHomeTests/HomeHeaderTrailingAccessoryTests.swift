import AppKit
import Testing
@testable import MessagesLabHome

/// The header's top-right controls (cmux: Home's panel toggles, like Claude desktop's): they sit
/// at the trailing edge on the avatar's line and take their own clicks, while the name pill keeps
/// its clicks and the header's empty space still drags the window.
@MainActor final class HomeHeaderTrailingAccessoryTests {
    private var retained: [NSView] = []
    /// Two 28 pt buttons with a gap, whose gap is not a hit (as Home's bar).
    final class TwoButtons: NSView {
        let left = NSButton(title: "L", target: nil, action: nil)
        let right = NSButton(title: "R", target: nil, action: nil)
        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(left)
            addSubview(right)
        }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 60, height: 28) }
        override func layout() {
            super.layout()
            left.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
            right.frame = NSRect(x: 32, y: 0, width: 28, height: 28)
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let p = convert(point, from: superview)
            return [left, right].first { $0.frame.contains(p) }
        }
    }

    /// A flipped superview at the header's frame, as the pane host is.
    final class Flipped: NSView {
        override var isFlipped: Bool { true }
    }

    private func header(width: CGFloat) -> (PaneHeaderView, TwoButtons) {
        let header = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: width, height: 80))
        let host = Flipped(frame: header.frame)
        host.addSubview(header)
        retained.append(host)
        header.title = "Chief"
        let accessory = TwoButtons(frame: .zero)
        header.trailingAccessory = accessory
        header.layoutSubtreeIfNeeded()
        accessory.layoutSubtreeIfNeeded()
        return (header, accessory)
    }

    /// A point in the header's flipped superview, which it fills from the origin.
    private func hit(_ header: PaneHeaderView, _ point: CGPoint) -> NSView? { header.hitTest(point) }

    @Test func theAccessorySitsTopRightOnTheAvatarsLine() {
        let (header, accessory) = header(width: 600)
        #expect(!accessory.isHidden)
        #expect(accessory.frame.maxX == 600 - PaneHeaderView.trailingInset)
        #expect(accessory.frame.size == NSSize(width: 60, height: 28))
        let avatarCenter = PaneHeaderView.avatarTop + PaneHeaderView.avatarSize / 2
        #expect(accessory.frame.midY == avatarCenter)
    }

    @Test func itsButtonsTakeTheirClicksAndThePillAndTheDragAreaKeepTheirs() {
        let (header, accessory) = header(width: 600)
        let f = accessory.frame
        #expect(hit(header, CGPoint(x: f.minX + 14, y: f.midY)) === accessory.left)
        #expect(hit(header, CGPoint(x: f.minX + 46, y: f.midY)) === accessory.right)
        // The gap between the buttons, and empty header space: the header (its window drag).
        #expect(hit(header, CGPoint(x: f.minX + 30, y: f.midY)) === header)
        #expect(hit(header, CGPoint(x: 40, y: 20)) === header)
        #expect(header.mouseDownCanMoveWindow)
        // The name pill still takes its clicks.
        #expect(hit(header, CGPoint(x: header.pill.frame.midX, y: header.pill.frame.midY)) === header.pill)
        // Nothing outside the header.
        #expect(hit(header, CGPoint(x: 40, y: 200)) == nil)
    }

    @Test func aPaneTooNarrowHidesItRatherThanCoverTheAvatar() {
        let (header, accessory) = header(width: 150)
        #expect(accessory.isHidden)
        #expect(hit(header, CGPoint(x: accessory.frame.midX, y: accessory.frame.midY)) !== accessory.right)
    }

    @Test func removingItLeavesThePlainHeader() {
        let (header, accessory) = header(width: 600)
        header.trailingAccessory = nil
        #expect(accessory.superview == nil)
        #expect(hit(header, CGPoint(x: 560, y: 28)) === header)
    }
}
