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

/// The empty field's trailing glyph. Messages 26.5 shows the dictation
/// microphone (New Message and SMS conversations) until audio has been sent;
/// Messages 27.0 has no in-field dictation and shows the record waveform in
/// New Message. Its disabled plus reads 190 (26.5) and 176 (27.0) on the
/// light glass.
@Suite struct ComposerTrailingGlyphTests {
    @Test func iOS26ShowsTheMicrophoneUntilAudioWasSent() {
        #expect(!ComposerBarGeometry.showsRecordGlyph(iOS27: false, sentAudio: false))
        #expect(ComposerBarGeometry.showsRecordGlyph(iOS27: false, sentAudio: true))
    }

    @Test func iOS27AlwaysShowsTheRecordWaveform() {
        #expect(ComposerBarGeometry.showsRecordGlyph(iOS27: true, sentAudio: false))
    }

    /// Messages 27.0 tints its disabled plus with tertiaryLabel's hue; on
    /// its glass the stroke reads 188 over 252 light and 96 over 59 dark,
    /// where ours (the label at 30 %) read 176 and 112.
    @Test func disabledPlusInk() {
        // 26.5 too tints it tertiaryLabel: 190 over 253 light, 60 over 26
        // dark (ours, the label at 24 %, read 192 and 81).
        #expect(ComposerBarGeometry.disabledPlusInk(iOS27: false) == .tertiaryHue(lightAlpha: 0.326, darkAlpha: 0.163))
        #expect(ComposerBarGeometry.disabledPlusInk(iOS27: true) == .tertiaryHue(lightAlpha: 0.335, darkAlpha: 0.21))
    }
}

/// Messages draws its record glyph itself (a 44 pt image shown at 22 pt):
/// five capsules 2 pt wide on a 4 pt pitch, 4, 8, 16, 8 and 4 pt tall,
/// centered. SF Symbols' `waveform` has six uneven bars.
@Suite struct ComposerRecordGlyphTests {
    @Test func fiveCenteredCapsules() {
        let bars = ComposerBarGeometry.recordGlyphBars
        #expect(ComposerBarGeometry.recordGlyphSide == 22)
        #expect(bars == [
            CGRect(x: 2, y: 9, width: 2, height: 4),
            CGRect(x: 6, y: 7, width: 2, height: 8),
            CGRect(x: 10, y: 3, width: 2, height: 16),
            CGRect(x: 14, y: 7, width: 2, height: 8),
            CGRect(x: 18, y: 9, width: 2, height: 4),
        ])
    }
}

/// Messages' To: field (ContactsUI's CNComposeRecipientActionButton) shows
/// SF Symbols' `plus.circle.fill` at the Title 1 text style, 32.67 pt at
/// Large, in label over secondarySystemFill, centered where our circle was.
@Suite struct ComposeRecipientAddGlyphTests {
    @Test func plusCircleFillAtTitle1() {
        #expect(ComposeRecipientAddGeometry.symbolName == "plus.circle.fill")
        #expect(ComposeRecipientAddGeometry.textStyleName == "title1")
    }

    @Test func centeredWhereMessagesDrawsIt() {
        // iPhone 17 Pro, iOS 27: the image view is 344.33, 149.67, 32.67 square
        // in a 370 pt capsule at x 16 whose last line ends 8 pt above its bottom.
        let frame = ComposeRecipientAddGeometry.frame(fieldWidth: 370, lineBottom: 48 - 8, side: 98.0 / 3)
        #expect(abs(frame.midX - (344.33 + 16.33 - 16)) < 0.05)
        #expect(abs(frame.midY - 24) < 0.01)
        #expect(frame.width == 98.0 / 3 && frame.height == 98.0 / 3)
    }
}

/// Messages centers the record glyph on the "+" (iOS 27.0, iPhone 17 Pro
/// New Message: field 516.7...557, plus 517...557, glyph 526...548, so its
/// center 537 is 20 pt above the field's bottom); ours centered it in the
/// 40.33 pt field, 0.17 pt higher and off the pixel grid (498.71).
@Suite struct ComposerRecordGlyphPlacementTests {
    @Test func glyphCentersOnThePlusRow() {
        let frame = ComposerBarGeometry.recordGlyphFrame(fieldBottom: 557, fieldTrailing: 386, scale: 3)
        #expect(frame.midY == 537)
        #expect(frame.minY == 526)
        #expect(frame.height == 22)
    }
}
