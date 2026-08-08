import CmuxTerminal
import Foundation

#if DEBUG
/// `debug.font.resolve` / `debug.font.rasterize` — authoritative font
/// resolution answers from the LIVE app (ghostty-web parity D3 service).
///
/// Mechanism: each item's grapheme cluster is pushed through the fork C API
/// `ghostty_surface_font_resolve_json` / `ghostty_surface_font_rasterize_json`,
/// which replays it into a scratch terminal (real grapheme clustering + SGR
/// styling), resolves it against the surface's shared font grid — the same
/// CodepointResolver/Collection instance the renderer uses, including any
/// fallback faces dynamic CoreText discovery added earlier in this session —
/// and shapes it with a private CoreText shaper carrying the surface's font
/// features. Rasterize additionally renders every resolved glyph through the
/// app's own Face/sprite render path into a private atlas and returns pixels
/// base64-encoded (16-bit little-endian coverage for monochrome, widened
/// losslessly from the pipeline's 8-bit coverage; premultiplied Display-P3
/// BGRA for color glyphs).
///
/// Batch contract: `items` is a JSON array of
/// `{cluster, bold?, italic?, constraint_width?}` (max 512 per call);
/// results come back in the same order, each either the parsed
/// `cmux.font-query.v1` document or `{"error": ...}`. Resolution order
/// matters: Ghostty's dynamic font fallback is session-order dependent, so
/// callers building a manifest must submit clusters in their canonical
/// repertoire order.
extension TerminalController {
    private static let v2FontQueryMaxBatch = 512

    nonisolated func v2DebugFontQuery(
        params: [String: Any],
        rasterize: Bool
    ) -> V2CallResult {
        let surfaceArg = ((params["surface_id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !surfaceArg.isEmpty else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        guard let rawItems = params["items"] as? [Any], !rawItems.isEmpty else {
            return .err(
                code: "invalid_params",
                message: "items must be a non-empty array of {cluster, bold?, italic?, constraint_width?}",
                data: nil
            )
        }
        guard rawItems.count <= Self.v2FontQueryMaxBatch else {
            return .err(
                code: "invalid_params",
                message: "items exceeds the \(Self.v2FontQueryMaxBatch)-item batch limit",
                data: nil
            )
        }

        struct Item {
            let cluster: String
            let bold: Bool
            let italic: Bool
            let constraintWidth: UInt8
        }
        var items: [Item] = []
        items.reserveCapacity(rawItems.count)
        for (index, raw) in rawItems.enumerated() {
            guard let dict = raw as? [String: Any],
                  let cluster = dict["cluster"] as? String,
                  !cluster.isEmpty else {
                return .err(
                    code: "invalid_params",
                    message: "items[\(index)] must be an object with a non-empty cluster string",
                    data: nil
                )
            }
            let constraintRaw = (dict["constraint_width"] as? Int) ?? 1
            guard constraintRaw == 1 || constraintRaw == 2 else {
                return .err(
                    code: "invalid_params",
                    message: "items[\(index)].constraint_width must be 1 or 2",
                    data: nil
                )
            }
            items.append(Item(
                cluster: cluster,
                bold: (dict["bold"] as? Bool) ?? false,
                italic: (dict["italic"] as? Bool) ?? false,
                constraintWidth: UInt8(constraintRaw)
            ))
        }

        return v2MainSync {
            guard let tabManager else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return .err(code: "not_found", message: "No tab selected", data: nil)
            }
            guard let panelId = resolveSurfaceId(from: surfaceArg, tab: tab),
                  let terminalPanel = tab.terminalInputTarget(forPanelID: panelId)?.panel else {
                return .err(code: "not_found", message: "Terminal surface not found", data: nil)
            }
            let surface = terminalPanel.surface

            var results: [[String: Any]] = []
            results.reserveCapacity(items.count)
            for item in items {
                if let document = surface.debugFontQueryJSON(
                    cluster: item.cluster,
                    bold: item.bold,
                    italic: item.italic,
                    constraintWidth: item.constraintWidth,
                    rasterize: rasterize
                ) {
                    results.append(document)
                } else {
                    results.append([
                        "cluster": item.cluster,
                        "error": "font query failed (surface not live or fork API rejected the cluster)",
                    ])
                }
            }
            return .ok([
                "surface_id": panelId.uuidString,
                "rasterize": rasterize,
                "items": results,
            ])
        }
    }
}
#endif
