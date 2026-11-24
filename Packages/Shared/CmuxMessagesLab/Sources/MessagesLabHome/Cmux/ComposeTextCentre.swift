import AppKit

/// Where the message field's text, caret and placeholder sit on its one-line height (#48467, the person: "is it just
/// me or is this not perfectly vertically aligned?"). MessagesLab puts them where Messages does: the first baseline
/// 20.25 pt under the field's top, the caret 7 pt under it. That left the line's optical centre, half way between its
/// capitals' centre and its lowercase letters' centre, about 1 pt under the field's centre, where the "+", the mic and
/// the send button are centred; the caret sat 0.5 pt low.
///
/// The text and the placeholder go up by ``textLift`` (the line's optical centre on the field's centre), the caret by
/// ``caretLift`` (its centre on the field's centre). The field's height and its growth by a line are unchanged: the
/// lift moves the text inside the field, not the field.
enum ComposeTextCentre {
    /// The one-line field's centre under its top: where the "+", the mic and the send button are centred.
    static let fieldCentre: CGFloat = ComposeMetrics.oneLine / 2

    /// The first line's optical centre under the line's baseline for `font`: half way between its capitals' centre
    /// and its lowercase letters' centre.
    static func opticalCentreAboveBaseline(_ font: NSFont) -> CGFloat { (font.capHeight + font.xHeight) / 4 }

    /// How far the text and the placeholder sit above MessagesLab's place.
    static let textLift: CGFloat = max(0, ComposeView.firstBaseline - opticalCentreAboveBaseline(ComposeView.font) - fieldCentre)

    /// Messages' caret: 17 pt tall, its top 13.25 pt above the first baseline.
    static let caretHeight: CGFloat = 17, caretTopAboveBaseline: CGFloat = 13.25

    /// How far the caret sits above MessagesLab's place: its centre on the field's centre.
    static let caretLift: CGFloat = max(0, ComposeView.firstBaseline - caretTopAboveBaseline + caretHeight / 2 - fieldCentre)

    /// What the field's own caret (placed against its text, which goes up by ``textLift``) moves down by, so that it
    /// goes up by ``caretLift`` in all.
    static let caretDrop: CGFloat = textLift - caretLift
}
