// cmux: the message box's pictures redraw without a layout (Draft+InlineMarks.swift). Not a vendored file.
import AppKit
import ObjectiveC

/// Draws again the message box's pictures whose thumbnails arrived: no layout, only their rects,
/// and every arrival of one main-actor turn in one update.
///
/// TextKit 2 draws the box's pictures itself (`ComposeInlineAttachment.image(for:...)`), and the
/// image it gets reads the thumbnail when it draws, so an arrival changes no layout. It used to lay
/// out the whole text (`invalidateLayout(for: documentRange)`): with N pictures pasted at once,
/// each of the N thumbnails laid out all N picture blocks again on the main thread (Lawrence
/// 2026-10-23, msg 11952: pasting several images lags). One per text view, kept with it; used on
/// the main thread only (the thumbnail lands there, and AppKit draws there).
final class ComposeInlineRedraw {
    private weak var field: NSTextView?
    /// The pictures whose thumbnails arrived since the last update.
    private var pending: [ObjectIdentifier: Weak] = [:]
    /// The update this turn's arrivals wait for (nil: none is scheduled).
    // task-owner: one per burst of arrivals; ends after its update
    private var scheduled: Task<Void, Never>?

    private struct Weak { weak var attachment: ComposeInlineAttachment? }

    private init(field: NSTextView) { self.field = field }

    /// FIELD's redraw (made with it the first time).
    static func of(_ field: NSTextView) -> ComposeInlineRedraw {
        if let made = objc_getAssociatedObject(field, redrawKey.pointer) as? ComposeInlineRedraw { return made }
        let made = ComposeInlineRedraw(field: field)
        objc_setAssociatedObject(field, redrawKey.pointer, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return made
    }

    /// ATTACHMENT's thumbnail arrived: its rect draws again with this turn's other arrivals.
    func arrived(_ attachment: ComposeInlineAttachment) {
        pending[ObjectIdentifier(attachment)] = Weak(attachment: attachment)
        guard scheduled == nil else { return }
        scheduled = Task { @MainActor [weak self] in self?.update() }
    }

    /// Marks the arrived pictures' rects (their layout fragments' frames) for drawing, in the
    /// field and the views TextKit 2 draws its fragments in. Nothing is laid out again.
    func update() {
        scheduled = nil
        let arrived = Set(pending.values.compactMap { $0.attachment.map(ObjectIdentifier.init) })
        pending = [:]
        guard !arrived.isEmpty, let field, let storage = field.textStorage, let tlm = field.textLayoutManager else { return }
        field.countInlineRedraw()
        var dirty = NSRect.null
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let a = value as? ComposeInlineAttachment, arrived.contains(ObjectIdentifier(a)),
                  let at = tlm.location(tlm.documentRange.location, offsetBy: range.location),
                  let fragment = tlm.textLayoutFragment(for: at) else { return }
            dirty = dirty.union(fragment.layoutFragmentFrame)
        }
        guard !dirty.isNull else { field.needsDisplay = true; return }
        let origin = field.textContainerOrigin
        Self.markForDrawing(field, dirty.offsetBy(dx: origin.x, dy: origin.y))
    }

    /// RECT (VIEW's coordinates) draws again in VIEW and every subview and sublayer it covers
    /// (TextKit 2 draws fragments in views or layers of its own, depending on the macOS).
    private static func markForDrawing(_ view: NSView, _ rect: NSRect) {
        view.setNeedsDisplay(rect)
        if let layer = view.layer { markForDrawing(layer, rect) }
        for sub in view.subviews where !sub.isHidden {
            let r = view.convert(rect, to: sub)
            if sub.bounds.intersects(r) { markForDrawing(sub, r.intersection(sub.bounds)) }
        }
    }

    private static func markForDrawing(_ layer: CALayer, _ rect: CGRect) {
        for sub in layer.sublayers ?? [] where !sub.isHidden {
            let r = layer.convert(rect, to: sub)
            guard sub.bounds.intersects(r) else { continue }
            sub.setNeedsDisplay(r.intersection(sub.bounds))
            markForDrawing(sub, r.intersection(sub.bounds))
        }
    }
}

// The associated-object key (its address only).
private let redrawKey = AssociationKey()
