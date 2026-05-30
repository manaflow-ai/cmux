import CmuxTerminalAccess
import Foundation

/// JSON wire-encoder for ``CmuxTerminalAccess/CellGrid``.
///
/// Emits the cells response shape defined by spec §7.2 plus locked
/// decisions:
/// - D25 — underline state lives on top-level `underline_kind` /
///   `underline_color` keys; the `attrs` array never carries an
///   `underline` value.
/// - D26 — `hyperlink` carries the OSC 8 URI string directly.
/// - D27 — top-level `semantic_available` boolean lets clients gate
///   semantic-aware UI without scanning every cell.
///
/// Lives in the app target because it has no AppKit dependencies but
/// is consumed only by the HTTP route layer. Tests assert the literal
/// JSON output using `JSONSerialization` with `.sortedKeys` so the
/// output is deterministic.
enum CellGridJSON {
    /// Encodes `g` as the `{"format":"cells", ...}` envelope.
    ///
    /// - Parameters:
    ///   - g: The grid snapshot returned by
    ///     ``CmuxTerminalAccess/SurfaceProvider/readCells(surface:region:)``.
    ///   - region: The wire string for the requested region (e.g.
    ///     `"viewport"` / `"screen"` / `"scrollback"`).
    static func encode(_ g: CellGrid, region: String) -> [String: Any] {
        [
            "format": "cells",
            "region": region,
            "cols": g.cols,
            "rows": g.rows,
            "alt_screen": g.altScreen,
            "title": g.title as Any,
            "semantic_available": g.semanticAvailable,
            "cursor": [
                "row": g.cursor.row,
                "col": g.cursor.col,
                "visible": g.cursor.visible,
                "style": cursorStyle(g.cursor.style),
            ] as [String: Any],
            "rows_data": g.rowsData.map { row in
                [
                    "wrap": row.wrap,
                    "wrap_continuation": row.wrapContinuation,
                    "cells": row.cells.map(cellJSON),
                ] as [String: Any]
            },
        ]
    }

    private static func cellJSON(_ c: Cell) -> [String: Any] {
        var out: [String: Any] = [
            "t": c.t,
            "wide": wideString(c.wide),
            "fg": colorString(c.fg),
            "bg": colorString(c.bg),
            "attrs": c.attrs
                .map(\.rawValue)
                .sorted(),
        ]
        if let kind = c.underlineKind {
            out["underline_kind"] = underlineString(kind)
            if let uc = c.underlineColor {
                out["underline_color"] = colorString(uc)
            }
        }
        if let h = c.hyperlink { out["hyperlink"] = h }
        if let s = c.semantic { out["semantic"] = semanticString(s) }
        return out
    }

    private static func cursorStyle(_ s: CursorStyle) -> String {
        switch s {
        case .block: return "block"
        case .underline: return "underline"
        case .bar: return "bar"
        }
    }

    private static func wideString(_ w: WideKind) -> String {
        switch w {
        case .narrow: return "narrow"
        case .wide: return "wide"
        case .spacerTail: return "spacer_tail"
        case .spacerHead: return "spacer_head"
        }
    }

    private static func colorString(_ c: CellColor) -> String {
        switch c {
        case .default: return "default"
        case .palette(let i): return "palette:\(i)"
        case .rgb(let r, let g, let b):
            return String(format: "#%02X%02X%02X", r, g, b)
        }
    }

    private static func underlineString(_ u: UnderlineKind) -> String {
        switch u {
        case .single: return "single"
        case .double: return "double"
        case .curly: return "curly"
        case .dotted: return "dotted"
        case .dashed: return "dashed"
        }
    }

    private static func semanticString(_ s: SemanticKind) -> String {
        switch s {
        case .prompt: return "prompt"
        case .promptContinuation: return "prompt_continuation"
        case .input: return "input"
        case .output: return "output"
        }
    }
}
