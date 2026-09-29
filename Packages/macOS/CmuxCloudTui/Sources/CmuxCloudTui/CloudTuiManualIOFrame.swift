import Foundation

/// One byte-oriented event delivered by a cmux-tui legacy `attach-surface` stream.
///
/// The native cloud pane consumes these events as terminal bytes. It deliberately
/// does not contain a rendered-cell representation: libghostty remains the only
/// renderer in a native pane.
public enum CloudTuiManualIOFrame: Equatable, Sendable {
    /// `colors` is the sparse sidecar that travels with a theme-portable replay
    /// or a palette-changing output chunk; `nil` means the frame carried none.
    ///
    /// A replay's `bytes` end at a parser boundary. `pending` is the incomplete
    /// escape sequence or UTF-8 code point the daemon's parser is inside; write
    /// it after the replay and its colors, immediately before later output.
    case snapshot(
        surfaceID: UInt64, columns: Int, rows: Int, bytes: Data,
        colors: CloudTuiRemoteColors? = nil, pending: Data = Data()
    )
    case output(surfaceID: UInt64, bytes: Data, colors: CloudTuiRemoteColors? = nil)
    case resized(
        surfaceID: UInt64, columns: Int, rows: Int, bytes: Data,
        colors: CloudTuiRemoteColors? = nil, pending: Data = Data()
    )
    case colorsChanged(surfaceID: UInt64, colors: CloudTuiRemoteColors)
    case detached(surfaceID: UInt64)
    case overflow(surfaceID: UInt64?)
    case response(
        requestID: UInt64,
        ok: Bool,
        lease: String?,
        capabilities: [String],
        outcome: String?,
        accepted: Bool?,
        error: String?
    )
    /// Undecoded envelope for the per-machine resource multiplexer.
    case message(Data)
}
