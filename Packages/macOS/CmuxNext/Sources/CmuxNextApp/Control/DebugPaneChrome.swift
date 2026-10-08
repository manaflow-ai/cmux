import AppKit
import CmuxNextDesign
import CmuxNextSettings

/// `debug.pane_chrome`: per pane of each window, the frames that must line
/// up (`PaneChromeMetrics`), in window points with a top-left origin: the
/// pane cell, the tab strip, the first tab pill, the content border, and
/// the terminal's first cell; plus the measured gaps (above and below the
/// pill, pill left minus border left, first cell minus border).
enum DebugPaneChrome {
    static func report(services: AppServices) -> JSONValue {
        let windows = services.windows.controllers.compactMap { controller -> JSONValue? in
            guard let window = controller.window, let layout = controller.content?.layoutView else { return nil }
            let height = window.frame.height
            func topLeft(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height) }
            let panes = layout.overlayRings.compactMap { ring -> JSONValue? in
                guard let pane = controller.content?.paneController(key: ring.pane) else { return nil }
                let view = pane.view
                let cell = topLeft(ring.frameInWindow)
                let border = topLeft(ring.contentInWindow)
                let strip = topLeft(view.stripView.convert(view.stripView.bounds, to: nil))
                let pill = view.stripView.firstTabPillFrame.map { topLeft(view.stripView.convert($0, to: nil)) }
                var firstCell: CGPoint?
                if case .terminal(let entry)? = pane.currentContent, entry.session.view.window === window {
                    let host = entry.session.view
                    let origin = host.firstCellOrigin
                    // The host is unflipped: its top-left is (minX, maxY).
                    let hostRect = topLeft(host.convert(host.bounds, to: nil))
                    firstCell = CGPoint(x: hostRect.minX + origin.x, y: hostRect.minY + origin.y)
                }
                var fields: [String: JSONValue] = [
                    "pane": .string(ring.pane),
                    "cell": rect(cell),
                    "strip": rect(strip),
                    "border": rect(border),
                    "pill": pill.map(rect) ?? .null,
                    "first_cell": firstCell.map { .array([.number(Double($0.x)), .number(Double($0.y))]) } ?? .null,
                ]
                if let pill {
                    fields["gap_above"] = .number(Double(pill.minY - cell.minY))
                    fields["gap_below"] = .number(Double(border.minY - pill.maxY))
                    fields["pill_left_minus_border_left"] = .number(Double(pill.minX - border.minX))
                }
                if let firstCell {
                    fields["first_cell_minus_border"] = .array([.number(Double(firstCell.x - border.minX)), .number(Double(firstCell.y - border.minY))])
                }
                return .object(fields)
            }
            return .object([
                "id": .string(controller.state.id),
                "scale": .number(Double(window.backingScaleFactor)),
                "pane_padding": .number(Double(Metrics.panePadding)),
                "panes": .array(panes),
                "window_controls": .object([
                    "sidebar_hidden": .bool(controller.root.sidebarHidden),
                    "toggle_symbol": .string(controller.root.toolbarBand.sidebarToggle.symbol),
                    "first_responder": .string(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"),
                ]),
                // 2026-10-05: the title bar buttons' reveal (top row or sidebar hover) and what is drawn.
                "titlebar_buttons": {
                    let root = controller.root, reveal = root.titlebarReveal.state, band = root.toolbarBand
                    return .object([
                        "revealed": .bool(reveal.isRevealed), "pointer_inside": .bool(reveal.pointerInside),
                        "holds": .number(Double(reveal.holds)), "focus_inside": .bool(reveal.focusInside),
                        "band_alpha": .number(Double(band.alphaValue)), "toggle_alpha": .number(Double(band.sidebarToggle.alphaValue)),
                        "back_alpha": .number(Double(band.backButton.alphaValue)),
                        "close_alpha": .number(Double(window.standardWindowButton(.closeButton)?.alphaValue ?? -1)),
                    ])
                }(),
            ])
        }
        return .object(["windows": .array(windows)])
    }

    private static func rect(_ rect: CGRect) -> JSONValue {
        .array([rect.minX, rect.minY, rect.width, rect.height].map { .number(Double($0)) })
    }
}
