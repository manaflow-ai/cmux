import CoreGraphics
import CmuxConversationGeometry
import Testing

/// "Send with effect" (long press on send), CKEffectPickerStandardView in
/// the iPhone 17 Pro simulators. The layout hangs off the send button where
/// the long press found it (keyboard up), identical on 26.5 and 27.0:
/// 27.0 send {341.67, 496, 38, 28} -> track {333.67, 256, 54, 215}, dots
/// 38 pt at y 259 / 316 / 373 / 430, labels ending at 311.67, draft bubble
/// ending at 313.67 with its body's bottom at 515.67; 26.5 send y 489 -> track y
/// 249, dots 252 ... 423. Title {20, 91, 362, 26.33}, segments {81, 132,
/// 240, 32} under a 62 pt safe top.
@Suite struct EffectPickerGeometryTests {
    let send27 = CGRect(x: 341.67, y: 496, width: 38, height: 28)

    @Test func trackAndDotsHangOffTheSendButton() {
        let g = EffectPickerGeometry(sendButton: send27, width: 402, safeTop: 62)
        #expect(abs(g.track.minX - 333.67) < 0.01 && g.track.minY == 256 && g.track.width == 54 && g.track.height == 215)
        #expect(g.dots.map(\.minY) == [259, 316, 373, 430])
        #expect(g.dots.allSatisfy { $0.minX == send27.minX && $0.width == 38 && $0.height == 38 })
        #expect(abs(g.labelTrailing - 311.67) < 0.01)
        #expect(g.cancel == send27)
    }

    @Test func draftBubbleSitsBesideTheCancelButton() {
        let g = EffectPickerGeometry(sendButton: send27, width: 402, safeTop: 62)
        // Body 40.33 tall (the tail hangs below it); Messages' body ends at 515.67.
        let bubble = g.homeBubble(size: CGSize(width: 124.08, height: 40.33))
        #expect(abs(bubble.maxX - 313.67) < 0.01)
        #expect(abs(bubble.maxY - 515.67) < 0.2)
        // Slam picked: the bubble moves up beside its dot, nearer the track.
        let picked = g.pickedBubble(size: CGSize(width: 124.08, height: 47.12), index: 0)
        #expect(abs(picked.minX - 204.09) < 0.05 && picked.minY == 260.5)
        #expect(EffectPickerGeometry.pickedLabelCenterY(bubble: picked) == 247.5)
    }

    @Test func headerUnderTheSafeArea() {
        let g = EffectPickerGeometry(sendButton: send27, width: 402, safeTop: 62)
        #expect(g.title == CGRect(x: 20, y: 91, width: 362, height: 26.33))
        #expect(g.segments == CGRect(x: 81, y: 132, width: 240, height: 32))
    }

    @Test func keyboardDownMovesEverythingWithTheSendButton() {
        let g26 = EffectPickerGeometry(sendButton: CGRect(x: 341.67, y: 489, width: 38, height: 28), width: 402, safeTop: 62)
        #expect(g26.track.minY == 249)
        #expect(g26.dots.first?.minY == 252 && g26.dots.last?.minY == 423)
    }
}
