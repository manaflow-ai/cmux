import CoreText
import Foundation
import GhosttyNextKit

/// One text Ghostty filled for a read (`ghostty_text_s`), copied into Swift and freed with
/// `ghostty_surface_free_text` before the initializer returns: the module's one owner of
/// Ghostty's text buffers, so no caller holds or frees the C text (ghostty.h: the text is owned
/// by the surface until it is freed).
nonisolated struct GhosttyTextRead {
    /// The UTF-8 bytes; empty when Ghostty filled no text.
    let bytes: [UInt8]
    /// The read's range in the screen text (selection reads).
    let range: NSRange
    /// The top-left corner of the read in pixels (selection reads).
    let topLeft: CGPoint

    /// The bytes as a string.
    var string: String { String(decoding: bytes, as: UTF8.self) }

    /// `ghostty_surface_read_text` of `selection` on `surface`, a live handle. Nil when Ghostty
    /// read nothing.
    init?(_ surface: ghostty_surface_t, selection: ghostty_selection_s) {
        // SAFETY: the caller's live surface; `$0` is this read's ghostty_text_s (fill below).
        unsafe self.init(surface) { unsafe ghostty_surface_read_text(surface, selection, $0) }
    }

    /// `ghostty_surface_read_selection` of `surface`, a live handle. Nil without a selection.
    init?(selectionOf surface: ghostty_surface_t) {
        // SAFETY: as in init(_:selection:).
        unsafe self.init(surface) { unsafe ghostty_surface_read_selection(surface, $0) }
    }

    /// `ghostty_surface_quicklook_word` of `surface`, a live handle: the word under the cursor.
    init?(quickLookWordOf surface: ghostty_surface_t) {
        // SAFETY: as in init(_:selection:).
        unsafe self.init(surface) { unsafe ghostty_surface_quicklook_word(surface, $0) }
    }

    /// Runs `fill`, one Ghostty read into the ghostty_text_s it gets, copies the text and frees it.
    private init?(_ surface: ghostty_surface_t, fill: (UnsafeMutablePointer<ghostty_text_s>) -> Bool) {
        var text = ghostty_text_s()
        // SAFETY: `fill` writes one ghostty_text_s into `text`, which lives for the call.
        guard unsafe withUnsafeMutablePointer(to: &text, { unsafe fill($0) }) else { return nil }
        // SAFETY: the text Ghostty filled for this read on the caller's live surface, freed once,
        // after the copy below.
        defer { unsafe ghostty_surface_free_text(surface, &text) }
        // SAFETY: the text Ghostty filled (above); only its address is read here.
        if let pointer = unsafe text.text, text.text_len > 0 {
            // SAFETY: Ghostty's text is text_len bytes at `text.text`, valid until the free above;
            // Array copies them.
            bytes = unsafe Array(UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)))
        } else {
            bytes = []
        }
        range = NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
        topLeft = CGPoint(x: text.tl_px_x, y: text.tl_px_y)
    }

    // Reads of a live surface that hand back plain values.

    /// `ghostty_surface_grid_metrics` of `surface`, a live handle; nil when Ghostty has none.
    static func gridMetrics(_ surface: ghostty_surface_t) -> ghostty_surface_grid_metrics_s? {
        var metrics = ghostty_surface_grid_metrics_s()
        // SAFETY: the caller's live surface; Ghostty writes one ghostty_surface_grid_metrics_s
        // into `metrics`, which lives for the call.
        return unsafe ghostty_surface_grid_metrics(surface, &metrics) ? metrics : nil
    }

    /// The font Ghostty uses for `surface`, a live handle (`ghostty_surface_quicklook_font`).
    static func quickLookFont(_ surface: ghostty_surface_t) -> CTFont? {
        // SAFETY: the caller's live surface; Ghostty returns a +1 CTFont (a Create-rule copy),
        // which takeRetainedValue balances once.
        guard let pointer = unsafe ghostty_surface_quicklook_font(surface) else { return nil }
        // SAFETY: as above.
        return unsafe Unmanaged<CTFont>.fromOpaque(pointer).takeRetainedValue()
    }
}
