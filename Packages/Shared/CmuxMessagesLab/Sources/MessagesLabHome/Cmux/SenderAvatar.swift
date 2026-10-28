import AppKit

/// The avatar a group transcript draws beside the last bubble of another
/// person's run (iMessage group chats): their monogram on a grey disc, or
/// their picture when the participant mapping has one (`Participant.Avatar`).
/// Carried by the part row (`PartRow.cmuxAvatar`) and drawn into the row's
/// bitmap with the bubble (`RowDraw.drawStatic`), so it costs nothing per
/// frame or keystroke.
enum SenderAvatar: Hashable, Sendable {
    /// One or two letters on a grey disc.
    case monogram(String)
    /// A picture by asset reference (`Images.load`).
    case image(String)

    /// The disc's diameter.
    static let diameter: CGFloat = 28
    /// The disc's left edge (row coordinates).
    static let left: CGFloat = 12
    /// How far a group's incoming bubbles move right of `Fixture.leftEdge` to
    /// clear the avatar column (the disc, plus room for the bubble's tail).
    static let bubbleInset: CGFloat = 28

    /// The avatar of a mapped participant (nil: none to draw).
    init?(_ avatar: Participant.Avatar?) {
        switch avatar {
        case let .monogram(text)?: self = .monogram(text)
        case let .image(ref)?: self = .image(ref)
        case nil: return nil
        }
    }

    /// The disc beside a bubble body: at the avatar column, its bottom on the body's bottom.
    static func rect(beside body: CGRect) -> CGRect {
        CGRect(x: left, y: body.maxY - diameter, width: diameter, height: diameter)
    }

    /// Draws the avatar in `rect` (a flipped row context, as `RowDraw` draws).
    /// Thread safe: row bitmaps draw on RowBitmaps' threads.
    func draw(in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.addEllipse(in: rect)
        ctx.clip()
        if case let .image(ref) = self, let img = Images.load(ref) {
            let s = max(rect.width / max(1, img.size.width), rect.height / max(1, img.size.height))
            let w = img.size.width * s, h = img.size.height * s
            img.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
            return
        }
        // Messages' monogram disc: a grey gradient, lighter at the top, white letters.
        let top = UIColor(red: 166 / 255, green: 170 / 255, blue: 180 / 255, alpha: 1).cgColor
        let bottom = UIColor(red: 134 / 255, green: 138 / 255, blue: 148 / 255, alpha: 1).cgColor
        if let gradient = CGGradient.checked(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom], locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        } else {
            ctx.setFillColor(bottom)
            ctx.fill(rect)
        }
        let text: String
        if case let .monogram(m) = self { text = String(m.prefix(2)) } else { text = "" }
        guard !text.isEmpty else { return }
        let font = HomeFonts.system(ofSize: text.count > 1 ? 11 : 13, weight: .semibold) // HomeFonts: shared by the row threads
        let w = TextDraw.width(text, font: font)
        TextDraw.line(text, font: font, color: .white, x: rect.midX - w / 2,
                      baseline: rect.midY + (font.capHeight / 2).rounded(), in: ctx)
    }
}
