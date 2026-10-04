import AppKit

/// The compose field's NSTextView: Return sends, Option/Shift+Return adds a
/// newline, Esc cancels, and pasted images become attachments (Catalyst's
/// `ComposeTextView` key commands). IME marked text, the caret and selection
/// are AppKit's own.
final class FieldTextView: NSTextView {
    var onSend: () -> Void = {}
    var onEscape: () -> Void = {}
    var onPasteImage: (NSImage) -> Void = { _ in }
    /// cmux: the host's attachment intake reads the pasteboard first
    /// (files and pictures, Home's type rule); true when it took the paste.
    var onPastePasteboard: (NSPasteboard) -> Bool = { _ in false }
    /// Marked (IME) text changed. UITextView reports marked text through
    /// `textViewDidChange`, so the draft (and the field height) follows the
    /// composition; NSTextView does not post a text change for it.
    var onMarkedTextChange: () -> Void = {}

    /// The inset as given (UITextView's 6.24 pt): AppKit rounds the
    /// container origin to whole points, which put the text 0.24 pt higher
    /// than Catalyst's (measured by the text probe's first baseline).
    override var textContainerOrigin: NSPoint { NSPoint(x: textContainerInset.width, y: textContainerInset.height) }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChange()
    }

    override func keyDown(with event: NSEvent) {
        // Marked text (IME composition) owns Return and Esc.
        if hasMarkedText() { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76 {
            if flags.contains(.option) || flags.contains(.shift) { insertText("\n", replacementRange: selectedRange()); return }
            onSend(); return
        }
        if event.keyCode == 53 { onEscape(); return }
        super.keyDown(with: event)
    }

    /// The pasteboard Paste reads (a check injects its own).
    var pasteboard: NSPasteboard = .general

    override func paste(_ sender: Any?) {
        let pb = pasteboard
        if onPastePasteboard(pb) { return }  // cmux
        if pb.string(forType: .string) == nil, let img = NSImage(pasteboard: pb) { onPasteImage(img); return }
        super.paste(sender)
    }
}

/// `compose.textView` for the shared window view: the NSTextView and its
/// layer (the shared code removes animations from it).
final class ComposeTextView {
    let view: FieldTextView
    var layer: CALayer { view.layer! }
    var onSend: () -> Void { get { view.onSend } set { view.onSend = newValue } }
    var onEscape: () -> Void { get { view.onEscape } set { view.onEscape = newValue } }
    var text: String { view.string }
    init() {
        // TextKit 2, as UITextView on Catalyst.
        view = FieldTextView(usingTextLayoutManager: true)
        view.wantsLayer = true
    }
    func insertText(_ s: String) { view.insertText(s, replacementRange: view.selectedRange()) }
}

/// Compose bar: "+" and emoji buttons, and the field with a real NSTextView.
/// Layers, geometry and springs are catalyst's current ComposeView
/// (catalyst/Sources/Compose.swift: fill, rim, veil and tint over a flying
/// bubble, the overlay that the window view puts above the morph), so
/// captures and the differential harness match it. In a live window
/// (`nativeChrome`) the drawn glass, rim, veil, tint and buttons are hidden:
/// AppKit's NSGlassEffectView field and glass buttons are there instead
/// (Host.swift), above the morph, and `onFieldResize` hands every field
/// height change to the window so the glass view's layer gets the same
/// render-server springs.
final class ComposeView: UIView {
    let textView = ComposeTextView()
    private let buttons = CanvasView()
    let glass = CALayer()
    private let placeholderLayer = CALayer()
    private let waveLayer = CALayer()
    /// What Messages draws above a bubble that flies out of the field (the
    /// window view moves it above its morph layer).
    let overlay = CALayer()
    static let overlayName = "composeGlassOverlay"
    private let veil = CALayer()
    private let tint = CALayer()
    private let rim = CALayer()
    static let rimFadeDepth = 0.45
    private let chipsLayer = CALayer()
    /// Catalyst's plus UIButton's layer (empty; keeps the layer order).
    private let plusLayer = CALayer()
    /// Capture mode draws its own caret (the text view's blinks on its own timer).
    let caret = CALayer()
    /// Capture mode: the text view's drawing, placed where the text view is
    /// (the NSTextView is not in the layer tree that captures render).
    let textSnapshot = CALayer()
    private(set) var fieldHeight: CGFloat = 30
    private(set) var chips: [Attachment] = []
    private(set) var text = ""
    private var placeholder = Strings.placeholder
    var captureMode = false {
        didSet {
            caret.isHidden = !captureMode
            textSnapshot.isHidden = !captureMode
            textView.view.insertionPointColor = captureMode ? .clear : Fixture.outgoing
        }
    }
    var onRemoveChip: (ID) -> Void = { _ in }
    /// Live window: AppKit materials replace the drawn glass and buttons.
    var nativeChrome = false {
        didSet { for l in [glass, rim, veil, tint, buttons.layer] { l.isHidden = nativeChrome } }
    }
    /// Field height changed in this transaction: (old, new, element, begin).
    var onFieldResize: ((CGFloat, CGFloat, SpringElement, CFTimeInterval) -> Void)?
    /// The send's field opacity pulse (begin), for the live glass view.
    var onSendPulse: ((CFTimeInterval) -> Void)?

    static func height(lines: Int, chips: Bool) -> CGFloat {
        30 + 16 * CGFloat(lines - 1) + (lines >= 2 ? 1 : 0) + (chips ? 30 : 0)
    }
    /// cmux: per view (several Home tabs), from this compose bar's width.
    var textWidth: CGFloat { ComposeView.fieldWidth(bounds.width) - 24 }
    static func fieldWidth(_ windowWidth: CGFloat) -> CGFloat { 526 + windowWidth - Fixture.windowWidth }
    static let font = Fixture.bodyFont
    static let maxLines = 8
    static let writingTools: NSWritingToolsBehavior = {
        let a = ProcessInfo.processInfo.arguments
        switch a.firstIndex(of: "--writing-tools").flatMap({ $0 + 1 < a.count ? a[$0 + 1] : nil }) {
        case "none": return .none
        case "complete": return .complete
        case "default": return .default
        default: return .limited
        }
    }()
    func lines(_ text: String) -> Int {
        min(ComposeView.maxLines, TextLayout.make(text.isEmpty ? " " : text, runs: [], maxWidth: textWidth, font: ComposeView.font).lines.count)
    }
    private var dx: CGFloat { bounds.width - Fixture.windowWidth }
    private var dy: CGFloat { bounds.height - Fixture.windowSize.height }
    var anchorBase: CGFloat { 984 + dy }
    var fieldBottom: CGFloat { 1030.25 + dy }
    static let fieldX: CGFloat = 51
    static let firstBaseline: CGFloat = 19.75

    static var typing: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = Fixture.lineHeight
        p.maximumLineHeight = Fixture.lineHeight
        return [.font: Fixture.bodyFont, .foregroundColor: Fixture.incomingText, .kern: Fixture.bodyKern, .paragraphStyle: p]
    }
    /// UITextView's text container inset above the first line (Catalyst value).
    static let textTopInset: CGFloat = ComposeView.firstBaseline - 13.26 - 0.25

    override init(frame: CGRect) {
        super.init(frame: frame)
        let none: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
        for l in [glass, placeholderLayer, waveLayer, chipsLayer, caret, textSnapshot, overlay, veil, rim, tint, plusLayer] {
            l.actions = none; l.contentsScale = DisplayScale.current
        }
        buttons.isUserInteractionEnabled = false
        buttons.drawer = { [unowned self] ctx, _ in self.drawButtons(ctx) }
        addSubview(buttons)
        glass.anchorPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(glass)
        layer.addSublayer(chipsLayer)
        overlay.name = ComposeView.overlayName
        veil.anchorPoint = CGPoint(x: 0.5, y: 1)
        veil.opacity = Animate.hiddenOpacity
        overlay.addSublayer(veil)
        tint.anchorPoint = CGPoint(x: 0.5, y: 1)
        tint.cornerRadius = 15
        tint.opacity = Animate.hiddenOpacity
        overlay.addSublayer(tint)
        rim.anchorPoint = CGPoint(x: 0.5, y: 1)
        overlay.addSublayer(rim)
        overlay.addSublayer(placeholderLayer)
        overlay.addSublayer(waveLayer)
        layer.addSublayer(textSnapshot)
        textSnapshot.isHidden = true
        textSnapshot.contentsGravity = .topLeft
        textSnapshot.masksToBounds = true

        let tv = textView.view
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.font = ComposeView.font
        tv.textColor = Fixture.incomingText
        tv.insertionPointColor = Fixture.outgoing
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = NSSize(width: 0, height: ComposeView.textTopInset)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.typingAttributes = ComposeView.typing
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.layerContentsPlacement = .topLeft
        tv.layer?.masksToBounds = true
        tv.layer?.contentsGravity = .topLeft
        tv.layer?.contentsScale = DisplayScale.current
        // Text services, decided explicitly (README: Text):
        // - continuous spell checking on (Messages underlines misspellings);
        //   grammar checking off;
        // - automatic spelling correction, text replacement and quote/dash
        //   substitution follow the user's system settings (NSSpellChecker's
        //   global switches), as in every AppKit text view;
        // - Writing Tools `.limited` by default: the panel from the context
        //   and Edit menus, no inline rewrite of the field;
        //   `--writing-tools none|limited|complete|default`.
        tv.isContinuousSpellCheckingEnabled = true
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = NSSpellChecker.isAutomaticSpellingCorrectionEnabled
        tv.isAutomaticTextReplacementEnabled = NSSpellChecker.isAutomaticTextReplacementEnabled
        tv.isAutomaticQuoteSubstitutionEnabled = NSSpellChecker.isAutomaticQuoteSubstitutionEnabled
        tv.isAutomaticDashSubstitutionEnabled = NSSpellChecker.isAutomaticDashSubstitutionEnabled
        tv.writingToolsBehavior = ComposeView.writingTools
        tv.setAccessibilityLabel(Strings.placeholder)

        caret.backgroundColor = NSColor(red: 0.04, green: 0.52, blue: 1, alpha: 1).cgColor
        caret.isHidden = true
        layer.addSublayer(caret)
        layer.addSublayer(plusLayer)
        layer.addSublayer(overlay)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var laidOut = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOut else { return }
        laidOut = bounds.size
        CATransaction.begin(); CATransaction.setDisableActions(true)
        overlay.frame = frame
        plusLayer.frame = plusRect
        CATransaction.commit()
        buttons.frame = CGRect(x: 0, y: 995 + dy, width: bounds.width, height: 40)
        buttons.setNeedsDisplay()
        renderGlass()
        renderPlaceholder()
        place(height: fieldHeight)
    }

    /// The display scale changed: draw every image again at the new scale.
    func rescale() {
        for l in [glass, placeholderLayer, waveLayer, chipsLayer, caret, textSnapshot, overlay, veil, rim] { l.contentsScale = DisplayScale.current }
        renderGlass()
        renderPlaceholder()
        renderChips()
        buttons.setNeedsDisplay()
    }

    /// The "+" button (opens the file picker).
    var plusRect: CGRect { CGRect(x: 10.5, y: 1000 + dy, width: 31, height: 30) }

    var fieldRect: CGRect { rect(height: fieldHeight) }
    func rect(height h: CGFloat) -> CGRect {
        CGRect(x: ComposeView.fieldX, y: fieldBottom - h - 0.25, width: ComposeView.fieldWidth(bounds.width), height: h)
    }

    /// Text view frame (window coordinates) for a field height.
    private func textFrame(height h: CGFloat) -> CGRect {
        let f = rect(height: h)
        let chipH: CGFloat = chips.isEmpty ? 0 : 30
        return CGRect(x: f.minX + 12, y: f.minY + chipH, width: f.width - 24 - (text.isEmpty ? 30 : 0), height: f.height - chipH)
    }

    private func place(height h: CGFloat) {
        let f = rect(height: h)
        let chipH: CGFloat = chips.isEmpty ? 0 : 30
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glass.bounds = CGRect(x: 0, y: 0, width: f.width, height: f.height)
        glass.position = CGPoint(x: f.midX, y: f.maxY)
        for l in [veil, rim, tint] { l.bounds = glass.bounds; l.position = glass.position }
        tint.backgroundColor = Fixture.background.withAlphaComponent(0.2).cgColor
        placeholderLayer.frame = CGRect(x: f.minX, y: f.minY + chipH, width: 300, height: 30)
        waveLayer.frame = CGRect(x: f.maxX - 30, y: f.maxY - 30, width: 24, height: 30)
        chipsLayer.frame = CGRect(x: f.minX, y: f.minY, width: f.width, height: 30)
        textSnapshot.frame = textFrame(height: h)
        CATransaction.commit()
        let tv = textFrame(height: h)
        if textView.view.frame != tv { textView.view.frame = tv }
    }

    /// Glass field image: top and bottom rims are fixed, the middle stretches.
    private func renderGlass() {
        let w = ComposeView.fieldWidth(bounds.width)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.opaque = false
        let h: CGFloat = 31
        glass.contents = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { _ in
            NSColor(white: 49 / 255, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 15).fill()
        }.cgImage
        rim.contents = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { ctx in
            Glass.drawRim(ctx.cgContext, rect: CGRect(x: 0, y: 0, width: w, height: h), radius: 15, rim: .field)
        }.cgImage
        for l in [glass, rim] {
            l.contentsCenter = CGRect(x: 0, y: 15 / h, width: 1, height: 1 / h)
            l.contentsScale = fmt.scale
        }
        renderVeil(width: w)
    }

    /// The glass over a bubble inside the field (catalyst's measured profile).
    private func renderVeil(width w: CGFloat) {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.opaque = false
        let cap: CGFloat = 20, h = 2 * cap + 1
        let top: [(CGFloat, CGFloat)] = [(0, 0.26), (6, 0.25), (9, 0.2), (13, 0.14), (16, 0.08), (18, 0.06), (20, 0)]
        let bottom: [(CGFloat, CGFloat)] = [(0, 0.35), (2, 0.34), (6, 0.29), (10, 0.2), (13, 0.14), (17, 0.08), (20, 0)]
        veil.contents = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { ctx in
            let c = ctx.cgContext
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            c.saveGState()
            UIBezierPath(roundedRect: rect, cornerRadius: 15).addClip()
            let grey = NSColor(white: 55 / 255, alpha: 1)
            let space = CGColorSpace(name: CGColorSpace.sRGB)
            for (stops, fromTop) in [(top, true), (bottom, false)] {
                let g = CGGradient(colorsSpace: space, colors: stops.map { grey.withAlphaComponent($0.1).cgColor } as CFArray,
                                   locations: stops.map { $0.0 / cap })!
                c.drawLinearGradient(g, start: CGPoint(x: 0, y: fromTop ? 0 : h), end: CGPoint(x: 0, y: fromTop ? cap : h - cap), options: [])
            }
            c.restoreGState()
        }.cgImage
        veil.contentsCenter = CGRect(x: 0, y: cap / h, width: 1, height: 1 / h)
        veil.contentsScale = fmt.scale
    }

    private func renderPlaceholder() {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.opaque = false
        let ph = placeholder
        placeholderLayer.contents = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 30), format: fmt).image { ctx in
            TextDraw.line(ph, font: ComposeView.font, color: Fixture.placeholder, x: 12, baseline: ComposeView.firstBaseline, in: ctx.cgContext)
        }.cgImage
        placeholderLayer.contentsScale = fmt.scale
        waveLayer.contents = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 30), format: fmt).image { _ in
            Fixture.waveform.setFill()  // cmux: themed (with the placeholder above)
            let c = CGPoint(x: 30 - 19.3 - 6, y: 30 - 15.25)
            for (i, hh) in ([4.7, 10.8, 15, 10.8, 4.7] as [CGFloat]).enumerated() {
                let x = c.x + CGFloat(i - 2) * 3.65
                UIBezierPath(roundedRect: CGRect(x: x - 0.7, y: c.y - hh / 2, width: 1.4, height: hh), cornerRadius: 0.7).fill()
            }
        }.cgImage
        waveLayer.contentsScale = fmt.scale
    }

    private func renderChips() {
        guard !chips.isEmpty else { chipsLayer.contents = nil; return }
        let f = fieldRect
        let fmt = UIGraphicsImageRendererFormat()
        fmt.opaque = false
        let list = chips
        chipsLayer.contents = UIGraphicsImageRenderer(size: CGSize(width: f.width, height: 30), format: fmt).image { ctx in
            var x: CGFloat = 8
            for a in list {
                let font = NSFont.systemFont(ofSize: 11, weight: .medium)
                let w = min(200, TextDraw.width(a.fileName, font: font) + 34)
                let r = CGRect(x: x, y: 5, width: w, height: 22)
                Fixture.chipFill.setFill()  // cmux: themed
                UIBezierPath(roundedRect: r, cornerRadius: 11).fill()
                TextDraw.line(a.fileName, font: font, color: Fixture.incomingText, x: r.minX + 10, baseline: r.minY + 15, in: ctx.cgContext)
                TextDraw.line("\u{2715}", font: .systemFont(ofSize: 9, weight: .bold), color: Fixture.secondaryText, x: r.maxX - 16,
                              baseline: r.minY + 15, in: ctx.cgContext)
                x += w + 6
            }
        }.cgImage
        chipsLayer.contentsScale = fmt.scale
    }

    func chip(at p: CGPoint) -> ID? {
        var x = fieldRect.minX + 8
        for a in chips {
            let w = min(200, TextDraw.width(a.fileName, font: .systemFont(ofSize: 11, weight: .medium)) + 34)
            if CGRect(x: x, y: fieldRect.minY + 5, width: w, height: 22).contains(p) { return a.id }
            x += w + 6
        }
        return nil
    }

    /// Mirror the draft and animate the field to its new height in this
    /// transaction (catalyst's `ComposeView.update`).
    func update(state: AppState, send: Bool, begin: CFTimeInterval) {
        let d = state.ui.draft
        let tv = textView.view
        if tv.string != d.text {
            // Never replace text that holds marked (IME) text: the input
            // method owns it until it commits.
            if !tv.hasMarkedText() {
                tv.textStorage?.setAttributedString(NSAttributedString(string: d.text, attributes: ComposeView.typing))
                tv.typingAttributes = ComposeView.typing
            }
        }
        let newPlaceholder = state.ui.openThread != nil ? Strings.replyPlaceholder : Strings.placeholder
        if newPlaceholder != placeholder { placeholder = newPlaceholder; renderPlaceholder(); tv.setAccessibilityLabel(placeholder) }
        if d.attachments != chips { chips = d.attachments; renderChips() }
        text = d.text
        CATransaction.begin(); CATransaction.setDisableActions(true)
        placeholderLayer.opacity = text.isEmpty ? 1 : 0
        waveLayer.opacity = text.isEmpty ? 1 : 0
        CATransaction.commit()
        let h = ComposeView.height(lines: lines(d.text), chips: !d.attachments.isEmpty)
        let old = fieldHeight
        fieldHeight = h
        place(height: h)
        if h != old {
            let e = send ? Springs.fieldTop : Springs.fieldGrow
            onFieldResize?(old, h, e, begin)
            Animate.scalar(glass, "bounds.size.height", from: Double(old), to: Double(h), e, begin: begin)
            for l in [veil, rim, tint] { Animate.scalar(l, "bounds.size.height", from: Double(old), to: Double(h), e, begin: begin) }
            let dTop = Double(h - old)
            for l in [placeholderLayer, chipsLayer] {
                Animate.scalar(l, "position.y", from: Double(l.position.y) + dTop, to: Double(l.position.y), e, begin: begin)
            }
            // The text view's top stays on the field top: Catalyst animates
            // the center by half the growth and the height by the growth
            // (anchor 0.5). AppKit's text view layer is anchored at its
            // top-left, so its top moves by the growth: the same frames.
            for l in [textView.layer, textSnapshot] {
                let top = l.anchorPoint.y == 0 ? dTop : dTop / 2
                Animate.scalar(l, "position.y", from: Double(l.position.y) + top, to: Double(l.position.y), e, begin: begin)
                Animate.scalar(l, "bounds.size.height", from: Double(l.bounds.height) - dTop, to: Double(l.bounds.height), e, begin: begin)
            }
        }
        if send {
            Animate.sampledPulse(glass, "opacity", Springs.fieldOpacity, base: 1, begin: begin)
            Animate.sampledPulse(rim, "opacity", Springs.fieldOpacity, base: 1, depth: ComposeView.rimFadeDepth, begin: begin)
            Animate.sampledUntilMinimum(veil, "opacity", Springs.fieldOpacity, base: 1, begin: begin)
            onSendPulse?(begin)
        }
    }

    /// The glass over a bubble still inside the field after the fill has
    /// faded (catalyst's `tintOverBubble`).
    func tintOverBubble(begin: CFTimeInterval, exit: CFTimeInterval) {
        let e = Springs.fieldOpacity
        let n = max(2, Int((exit - begin) * 240) + 1)
        var values: [Double] = (0...n).map { min(1, max(0, e.value(Double($0) / 240, from: 1, to: 1))) }
        let low = values.indices.min { values[$0] < values[$1] } ?? n
        for i in 0...n { values[i] = i < low || i == n ? 0 : 1 - values[i] }
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = values.map { NSNumber(value: $0) }
        a.keyTimes = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
        a.duration = Double(n) / 240
        a.beginTime = begin
        a.calculationMode = .linear
        a.fillMode = .backwards
        a.isRemovedOnCompletion = true
        tint.add(a, forKey: "tintOverBubble")
    }

    /// Capture mode: draw the text view into `textSnapshot` (the NSTextView
    /// draws itself; this only copies its pixels into the captured tree).
    func refreshTextSnapshot() {
        guard captureMode else { return }
        let tv = textView.view
        tv.layoutSubtreeIfNeeded()
        let size = tv.bounds.size
        guard size.width > 0, size.height > 0, let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds) else { return }
        tv.cacheDisplay(in: tv.bounds, to: rep)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        textSnapshot.contents = rep.cgImage
        textSnapshot.contentsScale = CGFloat(rep.pixelsWide) / max(1, size.width)
        CATransaction.commit()
    }

    /// Capture-mode caret (catalyst's `applyCaret`).
    func applyCaret(sinceEdit tau: Double, sinceSend: Double?) {
        guard captureMode else { return }
        refreshTextSnapshot()
        var alpha = 1.0, gray = false
        if let s = sinceSend, s >= 0, s < 0.65 { alpha = s < 0.02 ? 0 : 1; gray = true }
        else if tau >= 0.99 {
            let p = (tau - 0.99).truncatingRemainder(dividingBy: 1.0)
            alpha = p < 0.6 ? 1 : p < 0.65 ? 1 - (p - 0.6) / 0.05 : p < 0.95 ? 0 : (p - 0.95) / 0.05
        }
        let f = fieldRect
        let tl = TextLayout.make(text.isEmpty ? " " : text, runs: [], maxWidth: textWidth, font: ComposeView.font)
        let row = CGFloat(max(0, tl.lines.count - 1))
        let last = text.isEmpty ? "" : (text.components(separatedBy: "\n").last ?? "")
        let cx = f.minX + 12 + TextDraw.width(last, font: ComposeView.font, kern: Fixture.bodyKern)
        let base = f.minY + (chips.isEmpty ? 0 : 30) + ComposeView.firstBaseline
        CATransaction.begin(); CATransaction.setDisableActions(true)
        caret.frame = CGRect(x: cx.px, y: base - 12.5 + row * 16, width: 1, height: 16.5)
        caret.backgroundColor = (gray ? NSColor(white: 0.5, alpha: 1) : Fixture.caret).cgColor  // cmux: themed caret
        caret.opacity = Float(alpha)
        CATransaction.commit()
    }

    private func drawButtons(_ ctx: CGContext) {
        ctx.translateBy(x: 0, y: -(995 + dy))
        Glass.draw(ctx, rect: CGRect(x: 10.5, y: 1000 + dy, width: 31, height: 30), radius: 15, fill: 49, rim: .button)
        Glass.draw(ctx, rect: CGRect(x: 586.5 + dx, y: 1000 + dy, width: 31, height: 30), radius: 15, fill: 49, rim: .button)
        let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        if let img = UIImage(systemName: "plus", withConfiguration: cfg)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
            let s = img.size, c = CGPoint(x: 26, y: 1015.25 + dy)
            img.draw(in: CGRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height))
        }
        let c = CGPoint(x: 601.875 + dx, y: 1014.875 + dy)
        NSColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(x: c.x - 7.5, y: c.y - 7.5, width: 15, height: 15)).fill()
        NSColor(white: 51 / 255, alpha: 1).setFill()
        for ex in [-2.9, 2.9] as [CGFloat] {
            UIBezierPath(ovalIn: CGRect(x: c.x + ex - 1.1, y: c.y - 4.6, width: 2.2, height: 3.2)).fill()
        }
        let mouth = UIBezierPath()
        mouth.move(to: CGPoint(x: c.x - 5.2, y: c.y + 0.6))
        mouth.addLine(to: CGPoint(x: c.x + 5.2, y: c.y + 0.6))
        mouth.addCurve(to: CGPoint(x: c.x - 5.2, y: c.y + 0.6), controlPoint1: CGPoint(x: c.x + 4.8, y: c.y + 7.4),
                       controlPoint2: CGPoint(x: c.x - 4.8, y: c.y + 7.4))
        mouth.fill()
        NSColor.white.setFill()
        UIRectFill(CGRect(x: c.x - 4.2, y: c.y + 0.6, width: 8.4, height: 1.3))
    }
}
