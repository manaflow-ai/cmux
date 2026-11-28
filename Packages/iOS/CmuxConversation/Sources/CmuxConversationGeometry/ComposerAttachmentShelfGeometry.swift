import CoreGraphics
import Foundation

/// The composer's queued-photo shelf in Messages, measured on iOS 26.5 and
/// 27.0 (the two agree): ChatKit's `CKUIBehavior` constants, the shelf's
/// accessibility frames, and 60 fps recordings of Messages' Photos drawer.
///
/// The expanded field stacks, from its top: a 6 pt inset, the 155 pt shelf
/// (`entryViewMaxPluginShelfHeight`), a 6 pt inset
/// (`messageEntryContentViewPhotoPluginInsets`), a 1 pt divider
/// (`dividerHeight`) inset 16 pt from both sides, then the text row.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum ComposerAttachmentShelfGeometry {
    public static let previewHeight: CGFloat = 155
    /// Above and below the previews, before the first and after the last.
    public static let inset: CGFloat = 6
    public static let gap: CGFloat = 6
    public static let dividerHeight: CGFloat = 1
    public static let dividerSideInset: CGFloat = 16
    /// Preview corners: 12 pt continuous on both systems, whatever the
    /// field's own radius (20.1 pt in the simulators, 22.1 pt on an iPhone
    /// 17 Pro Max with a 44.3 pt field): Messages does not make them concentric.
    public static let previewCornerRadius: CGFloat = 12
    /// Previews never get narrower than this, however tall the photo.
    public static let minimumPreviewWidth: CGFloat = 60

    /// The field height the shelf and divider add above the text row.
    public static var bandHeight: CGFloat { inset + previewHeight + inset + dividerHeight }
    /// The divider's top, measured from the shelf band's top.
    public static var dividerY: CGFloat { inset + previewHeight + inset }

    /// The remove button: an 18 pt disc centered 14 pt in from the preview's
    /// right edge and 13.75 pt down from its top (`Cancel Button`).
    public static let removeDiscDiameter: CGFloat = 18
    public static let removeCenterInsetFromRight: CGFloat = 14
    public static let removeCenterInsetFromTop: CGFloat = 13.75

    /// When the first photo arrives, Messages flashes an 18 pt gray clear
    /// button at the shelf's top right (center 16 pt in from the right edge,
    /// 21.5 pt down) that fades out on the shelf spring as the field grows.
    public static let clearFlashCenterInsetFromRight: CGFloat = 16
    public static let clearFlashCenterInsetFromTop: CGFloat = 21.5

    /// A preview as wide as its photo at the shelf height, at most the
    /// shelf's width less its insets.
    public static func previewWidth(aspectRatio: CGFloat, shelfWidth: CGFloat) -> CGFloat {
        let maximum = max(1, shelfWidth - 2 * inset)
        return min(maximum, max(minimumPreviewWidth, (previewHeight * aspectRatio).rounded()))
    }

    /// Preview frames in the shelf's content coordinates, left to right.
    public static func previewFrames(aspectRatios: [CGFloat], shelfWidth: CGFloat) -> [CGRect] {
        var x = inset
        return aspectRatios.map { aspect in
            let width = previewWidth(aspectRatio: aspect, shelfWidth: shelfWidth)
            defer { x += width + gap }
            return CGRect(x: x, y: 0, width: width, height: previewHeight)
        }
    }

    public static func contentWidth(frames: [CGRect]) -> CGFloat {
        guard let last = frames.last else { return 0 }
        return last.maxX + inset
    }

    /// The offset that shows the newest preview: the strip scrolled to its end.
    public static func endOffset(contentWidth: CGFloat, shelfWidth: CGFloat) -> CGFloat {
        max(0, contentWidth - shelfWidth)
    }

    /// The offset after content shrinks: unchanged unless it now overscrolls.
    public static func clampedOffset(_ offset: CGFloat, contentWidth: CGFloat, shelfWidth: CGFloat) -> CGFloat {
        min(max(0, offset), endOffset(contentWidth: contentWidth, shelfWidth: shelfWidth))
    }

    /// Where a removed preview plays its exit, in content coordinates. Messages
    /// exits a preview in place, except the last of several: that one jumps
    /// to the first preview's origin and exits there, over the others.
    public static func exitFrame(removedIndex: Int, frames: [CGRect]) -> CGRect {
        let frame = frames[removedIndex]
        guard frames.count > 1, removedIndex == frames.count - 1 else { return frame }
        return CGRect(x: inset, y: frame.minY, width: frame.width, height: frame.height)
    }
}

/// The shelf's motion in Messages (iOS 26.5 and 27.0, 60 fps recordings).
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum ComposerAttachmentShelfMotion {
    /// Every move is one critically damped spring: the field growing for the
    /// first photo and collapsing after the last (fits within 0.7 pt rms on
    /// both systems), the strip scrolling to a new photo, the survivors
    /// closing a gap, a new preview's fade-in and a removed one's exit.
    /// ω = 18.2 rad/s.
    public static let springResponse: TimeInterval = 0.345
    /// Second phase of an append (the new preview fades in after the strip
    /// starts scrolling) and of a removal (the survivors slide after the
    /// removed preview starts its exit).
    public static let secondPhaseDelay: TimeInterval = 0.155
    /// A removed preview's remove button vanishes at the tap; its exit and
    /// the survivors' slide start this much later (0.06-0.07 s on both systems).
    public static let removalDelay: TimeInterval = 0.065
    /// The blur reaches full strength this early in the exit, so the
    /// preview fades as one opaque blurring image.
    public static let exitBlurRamp: TimeInterval = 0.04
    /// A removed preview shrinks toward this scale while it blurs and fades.
    public static let exitScale: CGFloat = 0.28
    /// Its blur at the end of the exit, in points.
    public static let exitBlurRadius: CGFloat = 12

    /// Progress of the critically damped spring `elapsed` seconds in.
    public static func progress(at elapsed: TimeInterval) -> CGFloat {
        guard elapsed > 0 else { return 0 }
        let omega = 2 * Double.pi / springResponse
        return CGFloat(1 - exp(-omega * elapsed) * (1 + omega * elapsed))
    }
}

/// The Photos drawer under the composer, Messages' app-card sheet: a card
/// inset 8 pt from the sides and bottom at ChatKit's custom "keyboard"
/// detent, so it takes the place of the keyboard it replaces. Its top sits
/// 5.3 pt below the keyboard's top (iPhone 17 Pro and Pro Max simulators on
/// 26.5 and 27.0, keyboards 328 to 347 pt, and a real iPhone 17 Pro Max with
/// a 318 pt keyboard), and the message field keeps the place the keyboard
/// gave it, 16 pt above the keyboard: 21.3 pt above the sheet.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum PhotoDrawerGeometry {
    /// Messages' large detent on iOS 26.5 stops this far under the safe
    /// area (iPhone 17 Pro: sheet top 72 with the safe top at 62); iOS 27.0
    /// fills to the safe area like UIKit's large detent.
    public static let iOS26LargeTopGap: CGFloat = 10

    /// The large detent's height from UIKit's maximum detent value.
    public static func largeDetentValue(maximum: CGFloat, leavesTopGap: Bool) -> CGFloat {
        leavesTopGap ? maximum - iOS26LargeTopGap : maximum
    }

    public static let inset: CGFloat = 8
    /// The sheet's top below the keyboard's top.
    public static let keyboardTopOffset: CGFloat = 5.3
    /// The field's bottom above the sheet's top.
    public static let fieldGap: CGFloat = 16 + keyboardTopOffset
    /// The docked software keyboard on an iPhone 17 Pro (335 pt), for when
    /// no keyboard has shown yet or only a hardware keyboard's bar did.
    public static let typicalKeyboardHeight: CGFloat = 335

    /// The sheet's height for a docked keyboard `keyboardHeight` tall
    /// (including the home-indicator inset, as UIKit reports it).
    public static func height(keyboardHeight: CGFloat) -> CGFloat {
        let keyboard = keyboardHeight >= 200 ? keyboardHeight : typicalKeyboardHeight
        return keyboard - keyboardTopOffset - inset
    }

    /// UIKit sizes a floating (inset) sheet this much taller than its custom
    /// detent's value (iOS 27.0, iPhone 17 Pro: 300 gives 320.7).
    public static let detentOverhang: CGFloat = 20.7

    /// The custom detent value that sizes the sheet `height` tall.
    public static func detentValue(height: CGFloat) -> CGFloat { height - detentOverhang }

    /// The strip along the sheet's top (the grabber's) that drags the sheet
    /// over the system picker.
    public static let grabberStripHeight: CGFloat = 20

    /// The picker's selection limit: "Select up to 50 items." in Messages
    /// 27, "Select up to 20 items." in Messages 26.5.
    public static func selectionLimit(iOS27: Bool) -> Int { iOS27 ? 50 : 20 }

    /// The composer's bottom constraint (below the safe area's bottom,
    /// `safeBottom`) for a sheet whose top is at `sheetTop`: its field rides
    /// `fieldGap` above the sheet at or below the keyboard detent
    /// (`restingSheetTop`), holds there while the sheet rises over it, and
    /// never drops below its base line (-4).
    public static func composerBottom(sheetTop: CGFloat, restingSheetTop: CGFloat, safeBottom: CGFloat) -> CGFloat {
        min(-4, max(sheetTop, restingSheetTop) - (fieldGap - 4) - safeBottom)
    }
}
