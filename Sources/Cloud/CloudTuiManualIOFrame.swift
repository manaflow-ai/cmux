import Foundation

/// One byte-oriented event delivered by a cmux-tui legacy `attach-surface` stream.
///
/// The native cloud pane consumes these events as terminal bytes. It deliberately
/// does not contain a rendered-cell representation: libghostty remains the only
/// renderer in a native pane.
enum CloudTuiManualIOFrame: Equatable, Sendable {
    /// `colors` is the sparse sidecar that travels with a theme-portable replay
    /// or a palette-changing output chunk; `nil` means the frame carried none.
    case snapshot(surfaceID: UInt64, columns: Int, rows: Int, bytes: Data, colors: CloudTuiRemoteColors? = nil)
    case output(surfaceID: UInt64, bytes: Data, colors: CloudTuiRemoteColors? = nil)
    case resized(surfaceID: UInt64, columns: Int, rows: Int, bytes: Data, colors: CloudTuiRemoteColors? = nil)
    case colorsChanged(surfaceID: UInt64, colors: CloudTuiRemoteColors)
    case detached(surfaceID: UInt64)
    case overflow(surfaceID: UInt64?)
    /// A `presence-changed` subscribe event (capability `presence-v1`).
    case presence(CloudPresenceEntry)
    case response(
        requestID: UInt64,
        ok: Bool,
        lease: String?,
        capabilities: [String],
        outcome: String?,
        accepted: Bool?,
        error: String?,
        selfClientID: UInt64?
    )
}
