public import Foundation
internal import GhosttyKit

/// cmux fork font-query C API (ghostty-web parity D3 resolution service):
/// resolve and rasterize grapheme clusters through the LIVE surface's font
/// pipeline (shared grid CodepointResolver/Collection with this session's
/// fallback discovery state, private CoreText shaper). See
/// `ghostty/include/ghostty.h` for the `cmux.font-query.v1` JSON contract.
extension TerminalSurface {
    /// Runs the fork's font resolve (or rasterize) export for one grapheme
    /// cluster and returns the parsed JSON document, or nil when the surface
    /// is not live or the call failed. Main actor for the surface liveness
    /// gate; the underlying C call is itself thread-safe against the shared
    /// font grid (it takes the grid's own locks, like concurrent renderer
    /// threads for split surfaces do).
    @MainActor
    public func debugFontQueryJSON(
        cluster: String,
        bold: Bool,
        italic: Bool,
        constraintWidth: UInt8,
        rasterize: Bool
    ) -> [String: Any]? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "debug.fontQuery") else {
            return nil
        }
        let utf8Count = UInt(cluster.utf8.count)
        guard utf8Count > 0 else { return nil }
        let exported = cluster.withCString { ptr in
            rasterize
                ? ghostty_surface_font_rasterize_json(
                    surface, ptr, utf8Count, bold, italic, constraintWidth
                )
                : ghostty_surface_font_resolve_json(
                    surface, ptr, utf8Count, bold, italic, constraintWidth
                )
        }
        defer { ghostty_string_free(exported) }
        guard let ptr = exported.ptr, exported.len > 0 else { return nil }
        let data = Data(bytes: ptr, count: Int(exported.len))
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }
}
