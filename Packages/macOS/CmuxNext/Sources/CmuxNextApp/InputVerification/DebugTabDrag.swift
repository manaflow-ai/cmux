#if DEBUG
import AppKit
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextSettings

/// `debug.tab_drag` (DEBUG builds): the live `TabDragSession` state, so a
/// `debug.mouse` drag (`release: false`) can be checked frame by frame:
/// pointer, grab offset, the ghost's presented geometry and where the
/// grabbed point of the tab image is on screen (`grab_error` is its
/// distance from the pointer while the ghost floats), the hit window, the
/// winning drop target and the outcome a release would commit.
enum DebugTabDrag {
    static func report(services: AppServices) -> JSONValue {
        let session = services.dragSession!
        guard let drag = session.drag ?? session.landing else {
            return .object(["dragging": .bool(false), "strips": strips(services)])
        }
        let layout = drag.ghost.layout(drag.motion)
        let grabbed = layout.onScreen(TabDragGhostLayout.grabPoint(in: layout.tab, grabOffset: drag.source.grabOffset,
                                                                   tabSize: drag.source.screenFrame.size))
        let presentation: String = switch drag.presentation {
        case .none: "none"
        case .card: "card"
        case .inline: "inline"
        }
        return .object([
            "dragging": .bool(session.drag === drag),
            "landing": .bool(session.landing === drag),
            "item": .string(String(describing: drag.source.item)),
            "point": point(drag.point),
            "grab_offset": point(drag.source.grabOffset),
            "source_frame": rect(drag.source.screenFrame),
            "presentation": .string(presentation),
            "ghost_tab": rect(layout.onScreen(layout.tab)),
            "ghost_card": rect(layout.onScreen(layout.card)),
            "ghost_cardness": .number(Double(layout.cardness)),
            "ghost_scale": .number(Double(layout.scale)),
            "ghost_settled": .bool(drag.motion.isSettled),
            "ghost_visible": .bool(drag.ghost.panel.isVisible),
            "ghost_panel_frame": rect(drag.ghost.panel.frame),
            "grab_point_on_screen": point(grabbed),
            "grab_error": .number(Double(hypot(grabbed.x - drag.point.x, grabbed.y - drag.point.y))),
            "window": session.window(at: drag.point).map { .string($0.state.id) } ?? .null,
            "winner": drag.winner.map { .string(String(describing: $0.proposal.kind)) } ?? .null,
            "highlight": drag.winner.map { rect($0.proposal.highlightFrame) } ?? .null,
            "outcome": .string(String(describing: drag.outcome)),
        ])
    }

    /// Every visible strip and its tabs, in `debug.mouse` coordinates
    /// (window-local points from the top-left), from the strips'
    /// accessibility elements.
    private static func strips(_ services: AppServices) -> JSONValue {
        var list: [JSONValue] = []
        for controller in services.windows.controllers {
            guard let window = controller.window, let height = window.contentView?.bounds.height else { continue }
            func topLeft(_ r: CGRect) -> JSONValue { rect(CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)) }
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
                let strip = pane.view.stripView
                guard strip.window === window, !strip.isHiddenOrHasHiddenAncestor else { continue }
                let tabs: [JSONValue] = (strip.accessibilityChildren() ?? []).compactMap { child in
                    guard let element = child as? NSAccessibilityElement else { return nil }
                    let frame = strip.convert(element.accessibilityFrameInParentSpace(), to: nil)
                    // Every point of the tab: no press there may move the window.
                    let samples = stride(from: frame.minX + 0.5, to: frame.maxX, by: 2).flatMap { x in
                        [frame.minY + 0.5, frame.midY, frame.maxY - 0.5].map { CGPoint(x: x, y: $0) }
                    }
                    let moving = samples.filter { TitlebarDragPolicy.decide(at: $0, in: window) == .movesWindow }.count
                    return .object(["label": .string(element.accessibilityLabel() ?? ""), "frame": topLeft(frame),
                                    "points_checked": .number(Double(samples.count)), "points_moving_window": .number(Double(moving))])
                }
                // Runs of strip x (debug.mouse coordinates) where a press moves the window.
                let bounds = strip.convert(strip.bounds, to: nil)
                var runs: [JSONValue] = []
                var runStart: CGFloat?
                for x in stride(from: bounds.minX, through: bounds.maxX, by: 1) {
                    let moves = TitlebarDragPolicy.decide(at: CGPoint(x: x, y: bounds.midY), in: window) == .movesWindow
                    if moves, runStart == nil { runStart = x }
                    if !moves || x + 1 > bounds.maxX, let start = runStart {
                        runs.append(.array([.number(Double(start)), .number(Double(x))]))
                        runStart = nil
                    }
                }
                list.append(.object([
                    "window": .string(controller.state.id), "pane": .string(pane.paneKey),
                    "frame": topLeft(bounds), "tabs": .array(tabs), "moves_window_x": .array(runs),
                    "band": topLeft(TitlebarDragPolicy.bandRect(in: window)),
                ]))
            }
        }
        return .array(list)
    }

    private static func point(_ p: CGPoint) -> JSONValue { .array([.number(Double(p.x)), .number(Double(p.y))]) }

    private static func rect(_ r: CGRect) -> JSONValue {
        .array([r.minX, r.minY, r.width, r.height].map { .number(Double($0)) })
    }
}
#endif
