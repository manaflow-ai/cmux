/// Per-event taxonomy for ``AuditEntry`` (D3).
///
/// One case per write/stream action recorded by
/// ``DefaultTerminalAccessService`` and the Phase 1 HTTP server. All
/// write paths emit audit entries unconditionally (D4 — audit is
/// ALWAYS-ON; Settings only controls the log file PATH).
///
/// Wire values are snake_case strings, matching the JSONL on-disk
/// log format.
public enum AuditKind: String, Sendable, Codable, Hashable {
    /// Plain-text write (`POST /surfaces/:id/input` with text payload).
    case writeText = "write_text"
    /// Structured key-events write.
    case writeKeys = "write_keys"
    /// Raw passthrough write (used for legacy passthroughs).
    case writeRaw = "write_raw"
    /// Bracketed-paste write.
    case writePaste = "write_paste"
    /// Mouse event write.
    case writeMouse = "write_mouse"
    /// Focus change event write.
    case writeFocus = "write_focus"
    /// New SSE output subscription opened.
    case streamOpen = "stream_open"
    /// SSE output subscription closed.
    case streamClose = "stream_close"
}
