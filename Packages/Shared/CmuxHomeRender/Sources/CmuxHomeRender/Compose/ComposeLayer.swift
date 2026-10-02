import CoreGraphics
import CoreText
import Foundation
import QuartzCore

/// The compose field: glass, placeholder, Core Text text and caret, all
/// layers, so its height change and the send fade are Core Animation springs
/// (no drawing per frame). Hosts place their own buttons beside the field
/// (`fieldRect`); the field leaves room for one on each side.
@MainActor
final class ComposeLayer {
    let layer = CALayer()
    let glass = CALayer()
    private let placeholderLayer = CALayer()
    let textClip = CALayer()
    private let textContent = CALayer()
    let caret = CALayer()
    private(set) var fieldHeight: CGFloat = ComposeLayer.height(lines: 1)
    private(set) var editor = ComposeEditor()
    private var size = CGSize.zero
    private var palette: HomePalette

    static let fieldX: CGFloat = 51
    static let sideRoom: CGFloat = 102
    static let maxLines = 8
    static let firstBaseline: CGFloat = 19.75
    /// The drawn first baseline below the field top (the text inset).
    static let textBaseline: CGFloat = 19.5
    static let bottomInset: CGFloat = 10.75
    /// The transcript's last row ends this far above the viewport bottom
    /// while the field has one line.
    static let anchorInset: CGFloat = 57

    static func height(lines: Int) -> CGFloat { 30 + 16 * CGFloat(lines - 1) + (lines >= 2 ? 1 : 0) }
    static func fieldWidth(_ viewportWidth: CGFloat) -> CGFloat { max(60, viewportWidth - sideRoom) }

    init(palette: HomePalette) {
        self.palette = palette
        for l in [layer, glass, placeholderLayer, textClip, textContent, caret] {
            l.actions = RowLayer.noActions
            l.contentsScale = Canvas.scale
        }
        glass.anchorPoint = CGPoint(x: 0.5, y: 1)
        textClip.masksToBounds = true
        textClip.anchorPoint = .zero
        textClip.addSublayer(textContent)
        for l in [glass, placeholderLayer, textClip, caret] { layer.addSublayer(l) }
        caret.backgroundColor = palette.caret.cgColor
    }

    var text: String { editor.text }
    var textWidth: CGFloat { Self.fieldWidth(size.width) - 24 }
    var fieldBottom: CGFloat { size.height - Self.bottomInset }
    /// Where the last transcript row ends with a one-line field.
    var anchorBase: CGFloat { size.height - Self.anchorInset }
    var fieldRect: CGRect { rect(height: fieldHeight) }
    var fieldTop: CGFloat { fieldRect.minY }

    func rect(height h: CGFloat) -> CGRect {
        CGRect(x: Self.fieldX, y: fieldBottom - h - 0.25, width: Self.fieldWidth(size.width), height: h + 0.25)
    }

    private var textLayout: TextLayout {
        TextLayout.make(text.isEmpty ? " " : text, maxWidth: textWidth, font: Style.bodyFont)
    }

    func lines(_ s: String) -> Int {
        min(Self.maxLines, TextLayout.make(s.isEmpty ? " " : s, maxWidth: textWidth, font: Style.bodyFont).lines.count)
    }

    func layout(size: CGSize) {
        guard size != self.size else { return }
        let widthChanged = size.width != self.size.width
        self.size = size
        layer.frame = CGRect(origin: .zero, size: size)
        if widthChanged {
            renderGlass()
            renderPlaceholder()
            renderText()
            fieldHeight = Self.height(lines: lines(text))
        }
        place(height: fieldHeight)
    }

    func setPalette(_ new: HomePalette) {
        guard new != palette else { return }
        palette = new
        caret.backgroundColor = new.caret.cgColor
        renderGlass()
        renderPlaceholder()
        renderText()
    }

    private func place(height h: CGFloat) {
        let f = rect(height: h)
        glass.bounds = CGRect(x: 0, y: 0, width: f.width, height: f.height)
        glass.position = CGPoint(x: f.midX, y: f.maxY)
        placeholderLayer.frame = CGRect(x: f.minX, y: f.minY, width: f.width, height: 30)
        textClip.bounds = CGRect(x: 0, y: 0, width: f.width - 24, height: f.height)
        textClip.position = CGPoint(x: f.minX + 12, y: f.minY)
        caret.frame = caretRect
    }

    /// The glass as a stretchable image (its middle row stretches with the height).
    private func renderGlass() {
        let w = Self.fieldWidth(size.width), h: CGFloat = 31
        let fill = palette.composeGlass
        glass.contents = Canvas.image(size: CGSize(width: w, height: h)) { ctx in
            Glass.draw(ctx, rect: CGRect(x: 0, y: 0, width: w, height: h), radius: 15, fill: fill)
        }
        glass.contentsCenter = CGRect(x: 0, y: 15 / h, width: 1, height: 1 / h)
    }

    private func renderPlaceholder() {
        let placeholder = HomeStrings.placeholder
        let color = palette.placeholder.cgColor
        placeholderLayer.contents = Canvas.image(size: CGSize(width: Self.fieldWidth(size.width), height: 30)) { ctx in
            TextDraw.line(placeholder, font: Style.bodyFont, color: color, x: 12, baseline: Self.firstBaseline, in: ctx)
        }
    }

    /// The text bitmap (redrawn on edits only), marked text underlined.
    private func renderText() {
        let tl = textLayout
        let w = textWidth, h = CGFloat(max(1, tl.lines.count)) * Style.lineHeight + 8
        textContent.frame = CGRect(x: 0, y: 0, width: w, height: h)
        let ed = editor
        guard !ed.text.isEmpty else { textContent.contents = nil; return }
        let color = palette.incomingText.cgColor
        textContent.contents = Canvas.image(size: CGSize(width: w, height: h)) { ctx in
            let a = NSMutableAttributedString(string: ed.text, attributes: TextDraw.attributes(Style.bodyFont, color, kern: Style.bodyKern))
            if let m = ed.marked { a.addAttribute(TextDraw.underlineKey, value: CTUnderlineStyle.single.rawValue, range: m) }
            for (i, line) in tl.lines.enumerated() where line.range.length > 0 {
                let ct = CTLineCreateWithAttributedString(a.attributedSubstring(from: line.range))
                TextDraw.draw(ct, x: 0, baseline: Self.textBaseline + CGFloat(i) * Style.lineHeight, ctx)
            }
        }
    }

    /// The caret rect in viewport points (also the IME candidate anchor).
    var caretRect: CGRect {
        let f = fieldRect
        let tl = textLayout
        let loc = editor.selection.location
        var row = 0
        for (i, l) in tl.lines.enumerated() where loc >= l.range.location { row = i }
        let ns = editor.text as NSString
        let start = row < tl.lines.count ? tl.lines[row].range.location : 0
        let prefix = loc >= start && loc <= ns.length ? ns.substring(with: NSRange(location: start, length: loc - start)) : ""
        let x = f.minX + 12 + TextDraw.width(prefix.replacingOccurrences(of: "\n", with: ""), font: Style.bodyFont, kern: Style.bodyKern)
        let base = f.minY + Self.firstBaseline
        return CGRect(x: x.px, y: base - 12.5 + CGFloat(row) * Style.lineHeight, width: 1, height: 16.5)
    }

    /// Applies an edit. Returns true when the text, selection or marked range changed.
    func edit(_ change: (inout ComposeEditor) -> Void) -> Bool {
        let before = editor
        change(&editor)
        guard editor != before else { return false }
        renderText()
        caret.frame = caretRect
        return true
    }

    /// Sets the text from outside (cleared by a send, restored after a refusal).
    func reset(_ text: String) {
        guard text != editor.text else { return }
        editor.reset(text)
        renderText()
    }

    /// Moves the field to the height its text needs in this transaction.
    /// `send`: the glass fades out and back and the height follows the fitted
    /// field spring.
    func settle(send: Bool, begin: CFTimeInterval, motion: MotionPolicy) {
        placeholderLayer.opacity = text.isEmpty ? 1 : 0
        let h = Self.height(lines: lines(text))
        let old = fieldHeight
        fieldHeight = h
        place(height: h)
        guard motion.moves else { return }
        if h != old {
            let e = motion(send ? HomeMotion.fieldTop : HomeMotion.fieldGrow)
            let dTop = Double(h - old)
            Animate.scalar(glass, "bounds.size.height", from: Double(old), to: Double(h), e, begin: begin)
            Animate.scalar(placeholderLayer, "position.y", from: Double(placeholderLayer.position.y) + dTop,
                           to: Double(placeholderLayer.position.y), e, begin: begin)
            Animate.scalar(textClip, "position.y", from: Double(textClip.position.y) + dTop, to: Double(textClip.position.y), e, begin: begin)
            Animate.scalar(textClip, "bounds.size.height", from: Double(textClip.bounds.height) - dTop,
                           to: Double(textClip.bounds.height), e, begin: begin)
        }
        if send { Animate.sampledPulse(glass, "opacity", motion(HomeMotion.fieldOpacity), base: 1, begin: begin) }
    }

    /// Solid caret after an edit, then a blink (render server).
    func restartCaret(begin: CFTimeInterval, sent: Bool, motion: MotionPolicy) {
        caret.frame = caretRect
        caret.backgroundColor = palette.caret.cgColor
        guard motion.caretBlinks else {
            caret.removeAllAnimations()
            return
        }
        Animate.caret(caret, begin: begin, sent: sent, gray: palette.caretAfterSend.cgColor)
    }

    /// Hosts that draw their own caret (or show none while unfocused) hide this one.
    var showsCaret = true { didSet { caret.isHidden = !showsCaret } }
}
