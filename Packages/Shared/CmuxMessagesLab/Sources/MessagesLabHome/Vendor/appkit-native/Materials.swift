import AppKit
import SwiftUI

// AppKit materials for the live window. Captures and the differential harness
// keep the shared drawn glass and fitted header blur (deterministic pixels);
// a live window shows these instead.

// MARK: Compose bar

/// The compose bar's Liquid Glass: the field (NSGlassEffectView behind the
/// text view) and the round "+" and emoji buttons (glass circles holding
/// borderless NSButtons), grouped in one NSGlassEffectContainerView so the
/// system renders them as one glass group (merging when closer than
/// `mergeSpacing`, as system glass does). The field follows the shared field
/// geometry; a height change is animated by `FieldAnimation`.
final class FieldChrome: NSView {
    let container = NSGlassEffectContainerView()
    private let group = FlippedView()
    let field = NSGlassEffectView()
    let plusGlass = NSGlassEffectView()
    let emojiGlass = NSGlassEffectView()
    let plus = NSButton()
    let emoji = NSButton()
    var onPlus: () -> Void = {}
    var onEmoji: () -> Void = {}
    /// Glass shapes closer than this merge (the "+" button is 9.5 pt from
    /// the field: separate at rest).
    static let mergeSpacing: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        container.spacing = FieldChrome.mergeSpacing
        container.contentView = group
        addSubview(container)
        field.cornerRadius = 15
        field.style = .regular
        group.addSubview(field)
        for (g, b, sym, label, sel) in [(plusGlass, plus, "plus", NativeStrings.attach, #selector(plusClicked)),
                                         (emojiGlass, emoji, "face.smiling", NativeStrings.emoji, #selector(emojiClicked))] {
            g.cornerRadius = 15
            g.style = .regular
            // cmux: by key (the macOS 27 SDK property is missing from Xcode 26.6's SDK).
            if #available(macOS 27.0, *), g.responds(to: NSSelectorFromString("setEffectIsInteractive:")) { g.setValue(true, forKey: "effectIsInteractive") }
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imagePosition = .imageOnly
            let cfg = FieldChrome.glyphConfig
            b.image = (sym == "face.smiling" ? FieldChrome.emojiGlyph(tinted: false) : NSImage(systemSymbolName: sym, accessibilityDescription: label)?.withSymbolConfiguration(cfg))
            b.image?.accessibilityDescription = label
            b.contentTintColor = .white
            b.setAccessibilityLabel(label)
            b.toolTip = label
            b.target = self
            b.action = sel
            g.contentView = b
            group.addSubview(g)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    /// Only the buttons take clicks; the field's clicks reach the text view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        for g in [plusGlass, emojiGlass] where g.frame.contains(p) { return g.contentView }
        return nil
    }
    @objc private func plusClicked() { onPlus() }
    @objc private func emojiClicked() { onEmoji() }

    override func layout() {
        super.layout()
        container.frame = bounds
        group.frame = bounds
    }

    func place(field f: CGRect, plus p: CGRect, emoji e: CGRect) {
        follow(field: f)
        if plusGlass.frame != p { plusGlass.frame = p }
        if emojiGlass.frame != e { emojiGlass.frame = e }
    }

    /// Model geometry (no animation), unless an animation is moving there.
    private var animatingTo: CGRect?
    func follow(field f: CGRect) {
        guard field.frame != f, animatingTo != f else { return }
        animatingTo = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        field.frame = f
        field.layoutSubtreeIfNeeded()
        CATransaction.commit()
    }

    /// The field grew or shrank by `new - old` in this transaction.
    func animateField(from old: CGFloat, to new: CGFloat, _ el: SpringElement, begin: CFTimeInterval) {
        guard let host = superview as? HostView, let demo = host.demo else { return }
        let target = demo.compose.fieldRect
        var start = target
        start.origin.y -= old - new
        start.size.height = old
        FieldAnimation.mode.run(self, from: start, to: target, el, begin: begin)
    }

    func setFrameNow(_ r: CGRect) {
        animatingTo = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        field.frame = r
        field.layoutSubtreeIfNeeded()
        CATransaction.commit()
    }
    func markAnimating(to r: CGRect) { animatingTo = r }

    /// The send's glass fade (catalyst's field opacity pulse): an opacity
    /// keyframe animation on the glass view's own layer (public: any
    /// layer-backed view's layer takes animations).
    func sendPulse(begin: CFTimeInterval) {
        guard let l = field.layer else { return }
        Animate.sampledPulse(l, "opacity", Springs.fieldOpacity, base: 1, begin: begin)
    }
}

/// How the glass field follows a height change (`--field-anim`). Measured with
/// `--probe-field` (presentation against model height of every layer in the
/// glass view while a 79 -> 30 pt send runs); see README.
enum FieldAnimation: String {
    /// AppKit's animator with the element's spring as the view's
    /// `frameOrigin`/`frameSize` animation (NSAnimatablePropertyContainer),
    /// layout inside the group: public API only, but AppKit sets the glass
    /// view's frame on the main thread every frame (measured: model height
    /// equals the presented height at every sample).
    case appkit
    /// NSAnimationContext.animate with the SwiftUI spring (public; AppKit
    /// lays the glass out every frame on the main thread).
    case swiftui
    /// Default. The shared spring added to the glass view's layer and to
    /// every internal layer that spans it: render server only (the model is
    /// at the final height from the first frame). Depends on the
    /// NSGlassEffectView's private layer structure; guarded: when no internal
    /// layer spans the glass, it falls back to `appkit`.
    case `internal`
    /// No animation: the glass takes the new size at once.
    case none

    static let mode: FieldAnimation = {
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: "--field-anim").flatMap { $0 + 1 < a.count ? FieldAnimation(rawValue: a[$0 + 1]) : nil } ?? .`internal`
    }()

    func run(_ chrome: FieldChrome, from start: CGRect, to target: CGRect, _ el: SpringElement, begin: CFTimeInterval) {
        let field = chrome.field
        guard let c = el.components.first else { chrome.setFrameNow(target); return }
        switch self {
        case .none:
            chrome.setFrameNow(target)
        case .appkit:
            chrome.setFrameNow(start)
            chrome.markAnimating(to: target)
            let spring = { (key: String) -> CASpringAnimation in
                let a = CASpringAnimation(keyPath: key)
                a.mass = 1
                a.stiffness = c.spring.stiffness
                a.damping = c.spring.damping
                a.duration = c.spring.settlingTime()
                return a
            }
            field.animations = ["frameOrigin": spring("frameOrigin"), "frameSize": spring("frameSize")]
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = c.spring.settlingTime()
                ctx.allowsImplicitAnimation = true
                field.animator().frame = target
                field.layoutSubtreeIfNeeded()
            }
        case .swiftui:
            chrome.setFrameNow(start)
            chrome.markAnimating(to: target)
            NSAnimationContext.animate(.spring(duration: c.spring.duration, bounce: c.spring.bounce)) {
                NSAnimationContext.current.allowsImplicitAnimation = true
                field.animator().frame = target
                field.layoutSubtreeIfNeeded()
            }
        case .`internal`:
            chrome.setFrameNow(target)
            guard let root = field.layer else { return }
            let new = target.height
            let d = Double(target.height - start.height)
            Animate.scalar(root, "bounds.size.height", from: Double(root.bounds.height) - d, to: Double(root.bounds.height), el, begin: begin)
            Animate.scalar(root, "position.y", from: Double(root.position.y) + d, to: Double(root.position.y), el, begin: begin)
            var found = 0
            func walk(_ l: CALayer) {
                for s in l.sublayers ?? [] {
                    if abs(s.bounds.height - new) < 0.01, abs(s.frame.minY) < 0.01 {
                        found += 1
                        let ay = Double(s.anchorPoint.y)
                        Animate.scalar(s, "bounds.size.height", from: Double(s.bounds.height) - d, to: Double(s.bounds.height), el, begin: begin)
                        if ay != 0 { Animate.scalar(s, "position.y", from: Double(s.position.y) - ay * d, to: Double(s.position.y), el, begin: begin) }
                    }
                    walk(s)
                }
            }
            walk(root)
            // Guard: no internal layer spans the glass (AppKit changed its
            // structure): fall back to AppKit's own animator.
            if found == 0 {
                root.removeAllAnimations()
                FieldAnimation.appkit.run(chrome, from: start, to: target, el, begin: begin)
            }
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: Tapback picker

/// Double-click picker: six tapbacks in a glass capsule above the bubble.
/// Real buttons (keyboard and VoiceOver reach each one).
final class TapbackPickerView: NSGlassEffectView {
    let ref: PartRef
    private let stack = NSStackView()
    private let selected: Reaction.Kind?
    private let pick: (Reaction.Kind) -> Void
    static let item: CGFloat = 34

    init(ref: PartRef, selected: Reaction.Kind?, pick: @escaping (Reaction.Kind) -> Void) {
        self.ref = ref
        self.selected = selected
        self.pick = pick
        super.init(frame: .zero)
        cornerRadius = 21
        style = .regular
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        for (i, t) in TapbackGlyph.all.enumerated() {
            let b = NSButton()
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.image = Self.glyph(t, on: selected == .tapback(t))
            b.tag = i
            b.target = self
            b.action = #selector(tapped(_:))
            b.setAccessibilityLabel(Strings.tapbackName(t))
            b.toolTip = Strings.tapbackName(t)
            b.widthAnchor.constraint(equalToConstant: Self.item).isActive = true
            b.heightAnchor.constraint(equalToConstant: Self.item).isActive = true
            stack.addArrangedSubview(b)
        }
        contentView = stack
        setAccessibilityLabel(Strings.menuTapback)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { NSSize(width: CGFloat(TapbackGlyph.all.count) * Self.item + 12, height: Self.item + 8) }

    @objc private func tapped(_ b: NSButton) { pick(.tapback(TapbackGlyph.all[b.tag])) }

    func rescale() {
        for case let b as NSButton in stack.arrangedSubviews { b.image = Self.glyph(TapbackGlyph.all[b.tag], on: selected == .tapback(TapbackGlyph.all[b.tag])) }
    }

    /// The row's own tapback drawing (emoji, or the HA HA glyph), as a
    /// resolution-independent NSImage (drawn at the destination's scale).
    static func glyph(_ t: String, on: Bool) -> NSImage {
        NSImage(size: NSSize(width: item, height: item), flipped: true) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            if on {
                Fixture.outgoing.setFill()
                NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).fill()
            }
            let inner = r.insetBy(dx: 7, dy: 7)
            if let e = TapbackGlyph.emoji(t) { PartRenderer.drawEmoji(e, in: inner, ctx: ctx) }
            else { TapbackGlyph.draw(t, in: inner.insetBy(dx: 2, dy: 2), color: on ? .white : NSColor(white: 0.85, alpha: 1), ctx: ctx) }
            return true
        }
    }
}

// MARK: Inline editor

/// Inline editor over a sent bubble: Return saves, Esc cancels.
final class InlineEditor: NSView {
    let textView = FieldTextView(usingTextLayoutManager: true)
    init(text: String, frame body: CGRect, maxX: CGFloat, commit: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        var f = body
        if f.width < 120 { f.size.width = 120; f.origin.x = min(body.minX, maxX - 120) }
        super.init(frame: f)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        layer?.cornerRadius = 15
        layer?.cornerCurve = .continuous
        layer?.borderColor = Fixture.outgoing.cgColor
        layer?.borderWidth = 1.5
        textView.frame = bounds.insetBy(dx: Fixture.bubblePadX, dy: 0)
        textView.drawsBackground = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: Fixture.textBaseline - 13.26)
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: ComposeView.typing))
        textView.typingAttributes = ComposeView.typing
        textView.insertionPointColor = Fixture.caret
        textView.isContinuousSpellCheckingEnabled = true
        textView.writingToolsBehavior = ComposeView.writingTools
        textView.setAccessibilityLabel(Strings.menuEdit)
        textView.onSend = { [weak textView] in commit(textView?.string ?? text) }
        textView.onEscape = cancel
        addSubview(textView)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
}

extension FieldChrome {
    /// Compose glyphs, fitted to the lossless stills: plus and emoji 15.5 pt medium.
    static let glyphConfig = NSImage.SymbolConfiguration(pointSize: 15.5, weight: .medium)
    /// Messages' emoji button glyph: the private SF Symbol `emoji.face.grinning`
    /// (CoreGlyphsPrivate.bundle, a named symbol image; README: Glyphs). Falls back to
    /// the public `face.smiling.inverse`. `tinted` bakes white in (layer drawing);
    /// the button tints it itself.
    static func emojiGlyph(tinted: Bool = true) -> NSImage? {
        let base = Bundle(path: "/System/Library/CoreServices/CoreGlyphsPrivate.bundle")?.image(forResource: "emoji.face.grinning")
            ?? NSImage(systemSymbolName: "face.smiling.inverse", accessibilityDescription: nil)
        guard let img = base?.withSymbolConfiguration(glyphConfig) else { return nil }
        guard tinted else { return img }
        return NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
        }
    }
}
