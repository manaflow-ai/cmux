// SPDX-License-Identifier: MIT

import Foundation

/// Discriminated input payload. Encoded as `{"type":"...", ...}` on the
/// HTTP wire. Phase 0 carries the type internally; Phase 1 adds the JSON
/// decoder.
public enum InputPayload: Sendable, Hashable {
    /// Literal text. `submit` appends CR (Enter) when true.
    case text(String, submit: Bool)
    /// Semantic key presses, encoded by ghostty against the active modes.
    case keys([KeyEvent])
    /// Raw bytes written verbatim. Gated by
    /// ``TerminalAccessService/allowRawInput``.
    case raw(Data)
    /// Explicit bracketed paste, atomic within one call per D30.
    case paste(String)
    /// Mouse event encoded by ghostty against active mouse mode. Per D16
    /// the dispatch path must NOT synthesize NSEvents.
    case mouse(MouseEvent)
    /// Focus gained/lost report (DEC 1004) via `ghostty_surface_set_focus`.
    /// Does NOT change macOS app focus.
    case focus(gained: Bool)
}
