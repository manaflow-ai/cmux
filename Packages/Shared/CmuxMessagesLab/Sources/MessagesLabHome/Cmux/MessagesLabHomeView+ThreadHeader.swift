import AppKit
import CmuxHomeCore

/// The message links of the native Home (HomeProjection+ThreadHeader.swift), and their DEBUG socket drives
/// (scripts/cmux-next/home-tree-thread-check.py).
extension MessagesLabHomeView {
    /// The build's link scheme (`cmux`, `cmux-dev`, `cmux-dev-<tag>`): "Copy Link" names messages in it.
    public var linkScheme: String? {
        get { projection.tree.linkScheme }
        set { projection.tree.linkScheme = newValue }
    }

    /// Automation (DEBUG socket), tree threads: `header` (`open`: a thread view is open; `header`: it draws anything above its root;
    /// Messages draws nothing, https://github.com/manaflow-ai/cmux/issues/26686) and `copy_link` {text} (Copy Link
    /// in the menu of that bubble; answers the pasteboard). nil: not a tree action.
    public func debugTreeDrive(_ action: String, _ args: [String: String]) -> [String: String]? {
        switch action {
        case "header":
            return ["open": controller.demo?.threadOpen == true ? "1" : "", "header": controller.demo?.threadHeaderFrame == nil ? "" : "1"]
        case "thread_rows":
            // The open thread view's rows, top first, as JSON in `rows`: each one's `kind` (part, replies, label,
            // separator, receipt, ...), `key`, `outgoing`, its content `frame` and, for a control row, the `control`
            // rect that takes its click (MessagesWindowView.threadRowControl), in window coordinates (AppKit: origin
            // at the bottom left; `windowHeight` is the content view's, for debug.mouse's top-left points), for clicks on its empty space (scripts/cmux-next/home-thread-click-away-clip.py).
            guard let demo = controller.demo, demo.threadOpen, let window = controller.host.window else { return ["ok": "0"] }
            func box(_ r: CGRect) -> [String: Double] {
                let w = controller.host.convert(r, to: nil)
                return ["x": Double(w.minX), "y": Double(w.minY), "width": Double(w.width), "height": Double(w.height)]
            }
            let rows: [[String: Any]] = zip(demo.threadViews, demo.threadSpecs).map { v, spec in
                let (kind, outgoing): (String, Bool) = switch spec.kind {
                case let .part(p): ("part", p.outgoing)
                case let .replies(_, _, o): ("replies", o)
                case let .label(_, o, _): ("label", o)
                case .separator: ("separator", false)
                case .receipt: ("receipt", true)
                case let .threadPreview(pv): ("preview", pv.outgoing)
                default: ("other", false)
                }
                var row: [String: Any] = ["kind": kind, "key": spec.key, "outgoing": outgoing,
                                          "frame": box(v.frame.insetBy(dx: 0, dy: RowDraw.margin))]
                if case .part = spec.kind { row["bubble"] = box(RowDraw.bodyRect(spec).offsetBy(dx: v.frame.minX, dy: v.frame.minY)) }
                if let c = MessagesWindowView.threadRowControl(spec, frame: v.frame) { row["control"] = box(c) }
                return row
            }
            let json = (try? JSONSerialization.data(withJSONObject: ["rows": rows, "windowHeight": Double(window.contentView?.bounds.height ?? window.frame.height)]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return ["ok": "1", "rows": json]
        case "copy_link":
            guard let hit = debugBubble(text: args["text"] ?? ""),
                  let menu = controller.menu(at: CGPoint(x: hit.body.midX, y: hit.body.midY)) else { return ["ok": "0"] }
            controller.menuHighlight?.discard(); controller.menuHighlight = nil // never shown
            guard let item = menu.items.first(where: { ($0 as? MenuAction)?.label == CmuxStrings.copyLink }),
                  let run = item.action else { return ["ok": "0", "error": "no Copy Link"] }
            NSApp.sendAction(run, to: item.target, from: item)
            return ["ok": "1", "link": NSPasteboard.general.string(forType: .string) ?? ""]
        case "picture":
            // {index, compare, mark} as "1"/"": the newest table's picture in the large picture viewer; `style` (side,
            // flip, slider) and `show` (before, after) set the comparison as its style control and B / A keys do.
            let style: HomePictureCompare.Style? = switch args["style"] { case "side": .sideBySide; case "flip": .flip; case "slider": .slider; default: nil }
            let show: HomePictureViewer.Key? = switch args["show"] { case "before": .before; case "after": .after; default: nil }
            let ok = debugOpenTablePicture(index: Int(args["index"] ?? "0", radix: 10) ?? 0, compare: args["compare"] == "1", mark: args["mark"] == "1",
                                           style: style, show: show)
            return ["ok": ok ? "1" : "0"]
        default:
            return nil
        }
    }
}
