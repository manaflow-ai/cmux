import CmuxTerminalAccess
import Foundation

/// JSON formatters for SSE event payloads (spec §9).
///
/// Centralised so both ``SSEResponder`` and tests share a single path
/// for "an ``OutputEvent`` becomes this JSON string". The encoders here
/// never throw — bad input falls back to ``"{}"`` rather than aborting
/// the stream — because they sit on the SSE hot path and we'd rather
/// emit a malformed-but-recoverable frame than tear the subscription
/// down on a producer-side bug.
public enum StreamPayloads {
    /// Encodes raw PTY bytes as a base64 JSON object.
    ///
    /// Shape: ``{"bytes_base64":"<b64>"}``. The base64 alphabet is
    /// standard (RFC 4648) — same as ``Data/base64EncodedString``.
    public static func rawPayload(_ data: Data) -> String {
        "{\"bytes_base64\":\"\(data.base64EncodedString())\"}"
    }

    /// Encodes a ``CellGrid`` snapshot using the same wire shape as
    /// ``CellGridJSON/encode(_:region:)`` (the `/screen?format=cells`
    /// response). Reusing the encoder keeps the cells SSE frames and
    /// the one-shot screen reads byte-identical for the same grid.
    public static func cellsPayload(_ grid: CellGrid) -> String {
        let dict = CellGridJSON.encode(grid, region: "viewport")
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.sortedKeys]
        ) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
