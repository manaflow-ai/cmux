import CmuxConversationGeometry
import CoreGraphics
import Testing

/// Expected frames are Messages' own on iOS 26.5 and 27.0 (identical),
/// read from MobileSMS's accessibility tree and pixel edges at @3x.
@Suite struct ComposerBarGeometryTests {
    /// One line of 17 pt body text plus 10 pt above and below.
    let oneLine: CGFloat = 20.287109375 + 20

    func row(width: CGFloat, fieldBottom: CGFloat, keyboardProgress: CGFloat, keyboardInset: CGFloat, fieldHeight: CGFloat? = nil) -> ComposerBarGeometry.Layout {
        let inset = ComposerBarGeometry.sideInset(keyboardProgress: keyboardProgress, keyboardInset: keyboardInset)
        return ComposerBarGeometry.layout(
            width: width, fieldBottom: fieldBottom, fieldHeight: fieldHeight ?? oneLine,
            oneLineHeight: oneLine, sideInset: inset, scale: 3
        )
    }

    func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.34) -> Bool { abs(a - b) <= tolerance }

    /// iPhone 17 Pro Max (440 pt), keyboard up: + {20,555,40,40}, field
    /// x 72 to 420, send {375.67,561,38,28}.
    @Test func proMaxKeyboardUp() {
        let r = row(width: 440, fieldBottom: 1664.0 / 3 + oneLine, keyboardProgress: 1, keyboardInset: 20)
        #expect(r.plus == CGRect(x: 20, y: 555, width: 40, height: 40))
        #expect(r.field.minX == 72)
        #expect(r.field.maxX == 420)
        #expect(close(r.field.minX + r.send.minX, 375.67))
        #expect(close(r.field.minY + r.send.minY, 561))
        #expect(r.send.size == CGSize(width: 38, height: 28))
    }

    /// 440 pt at rest: + {28,888,40,40}, field x 80 to 412, send x 367.67.
    @Test func proMaxAtRest() {
        let r = row(width: 440, fieldBottom: 2663.0 / 3 + oneLine, keyboardProgress: 0, keyboardInset: 20)
        #expect(r.plus == CGRect(x: 28, y: 888, width: 40, height: 40))
        #expect(r.field.minX == 80)
        #expect(r.field.maxX == 412)
        #expect(close(r.field.minX + r.send.minX, 367.67))
        #expect(close(r.field.minY + r.send.minY, 894))
    }

    /// iPhone 17 Pro (402 pt): + at 28 at rest and 16 with the keyboard up.
    @Test func proInsets() {
        #expect(row(width: 402, fieldBottom: 846, keyboardProgress: 0, keyboardInset: 16).plus.minX == 28)
        let up = row(width: 402, fieldBottom: 523, keyboardProgress: 1, keyboardInset: 16)
        #expect(up.plus.minX == 16)
        #expect(up.field.maxX == 386)
    }

    /// The send capsule's margins inside the field: 6.33 pt trailing, 6.33
    /// above and 6 below on one line (a field whose top is on a pixel).
    @Test func sendMargins() {
        let r = row(width: 440, fieldBottom: 1664.0 / 3 + oneLine, keyboardProgress: 1, keyboardInset: 20)
        #expect(close(r.field.width - r.send.maxX, 6.33, 0.01))
        #expect(close(r.send.minY, 6.33, 0.01))
        #expect(close(oneLine - r.send.maxY, 6, 0.05))
    }

    /// A taller field grows upward; the "+" and send stay on the last line.
    @Test func growingFieldKeepsPlusAndSendOnTheLastLine() {
        let one = row(width: 440, fieldBottom: 600, keyboardProgress: 1, keyboardInset: 20)
        let three = row(width: 440, fieldBottom: 600, keyboardProgress: 1, keyboardInset: 20, fieldHeight: oneLine + 2 * 20.287109375)
        #expect(three.plus == one.plus)
        #expect(close(three.field.minY + three.send.minY, one.field.minY + one.send.minY, 0.01))
        #expect(three.field.maxY == one.field.maxY)
    }

    /// The inset moves with the keyboard, monotonically, between the ends.
    @Test func insetFollowsKeyboardProgress() {
        var previous = CGFloat.infinity
        for step in 0...10 {
            let inset = ComposerBarGeometry.sideInset(keyboardProgress: CGFloat(step) / 10, keyboardInset: 16)
            #expect(inset <= previous)
            previous = inset
        }
        #expect(ComposerBarGeometry.sideInset(keyboardProgress: 0, keyboardInset: 16) == 28)
        #expect(ComposerBarGeometry.sideInset(keyboardProgress: 1, keyboardInset: 16) == 16)
        #expect(ComposerBarGeometry.sideInset(keyboardProgress: 2, keyboardInset: 16) == 16)
    }
}
