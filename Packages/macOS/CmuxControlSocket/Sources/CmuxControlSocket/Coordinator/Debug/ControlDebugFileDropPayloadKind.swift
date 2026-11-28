#if DEBUG
/// The synthesized pasteboard payload for `debug.terminal.simulate_file_drop`
/// (the package twin of the legacy body's local
/// `TerminalFileDropSimulationPayload`).
public enum ControlDebugFileDropPayloadKind: Sendable, Equatable {
    /// File URLs (`file` / `files` / `file_url` / `file_urls`, the default).
    case fileURLs
    /// In-memory image data (`image` / `image_data` / `images`).
    case imageData
}
#endif
