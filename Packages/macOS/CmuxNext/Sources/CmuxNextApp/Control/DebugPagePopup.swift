#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextSettings
import CmuxNextDesign

/// `debug.page_popup`: each page menu showing past its window's edge (cx-6k6cg, WebPopupHost):
/// its frame and its window's (screen points), its rows, whether every row shows (`clipped` false:
/// the frame is as tall as the rows) and whether it is all on its screen.
enum DebugPagePopup {
    static func list() -> JSONValue {
        .object(["popups": .array(NSApp.windows.compactMap { window -> JSONValue? in
            guard let panel = window as? WebPopupPanel, panel.isVisible, !panel.isClosing else { return nil }
            let screen = panel.screen?.visibleFrame ?? .zero
            let card = panel.cardFrame
            return .object([
                "frame": rect(card),
                "window": panel.parent.map { rect($0.frame) } ?? .null,
                "rows": JSONValue(panel.rowCount),
                "content_height": .number(panel.contentHeight),
                "clipped": .bool(card.height + 0.5 < panel.contentHeight),
                "on_screen": .bool(screen.insetBy(dx: -0.5, dy: -0.5).contains(card)),
            ])
        })])
    }

    private static func rect(_ rect: CGRect) -> JSONValue {
        .object(["x": .number(rect.minX), "y": .number(rect.minY), "width": .number(rect.width), "height": .number(rect.height)])
    }
}
#endif
