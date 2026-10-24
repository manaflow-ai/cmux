#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
import CmuxNextSettings

/// The shown hover card's glyphs and labels (`debug.hover_sweep` with a `point`), in card points
/// with a top-left origin: each visible image or shared status indicator, and each visible text
/// line. scripts/cmux-next/hover-card-grid-live.py checks them against the card grid (Leo
/// 2026-10-13: every icon legible at its size, labeled, on the grid).
@MainActor
enum DebugCardGrid {
    static func report() -> JSONValue {
        guard let panel = NSApp.windows.first(where: { String(describing: type(of: $0)) == "HoverCardPanel" && $0.isVisible }),
              let root = panel.contentView
        else { return .null }
        // The card in window coordinates (the host fills the window; the card sits inside its
        // shadow band and the slide's room).
        let card = (root as? PopupHostView)?.card.frame
            ?? PopupStyle.standard.cardFrame(inWindow: panel.frame).offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
        var glyphs: [JSONValue] = []
        var labels: [JSONValue] = []
        func frame(_ view: NSView) -> JSONValue {
            let rect = view.convert(view.bounds, to: nil)
            return .array([rect.minX - card.minX, card.maxY - rect.maxY, rect.width, rect.height].map { .number(Double($0)) })
        }
        func walk(_ view: NSView) {
            guard !view.isHidden, view.alphaValue > 0 else { return }
            if let indicator = view as? StatusIndicatorView {
                if indicator.showsGlyph {
                    glyphs.append(.object(["kind": .string("indicator"), "state": .string(String(describing: indicator.state)), "frame": frame(indicator)]))
                }
                return
            }
            if let image = view as? NSImageView, image.image != nil {
                glyphs.append(.object(["kind": .string("image"), "frame": frame(image)]))
                return
            }
            if let label = view as? any ShownText, !label.stringValue.isEmpty {
                labels.append(.object(["text": .string(label.stringValue), "frame": frame(label)]))
                return
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return .object([
            "size": .array([.number(Double(card.width)), .number(Double(card.height))]),
            "glyphs": .array(glyphs),
            "labels": .array(labels),
        ])
    }
}
#endif
