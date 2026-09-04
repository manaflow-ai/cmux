import Foundation

/// One byte-oriented event delivered by a cmux-tui legacy `attach-surface` stream.
///
/// The native cloud pane consumes these events as terminal bytes. It deliberately
/// does not contain a rendered-cell representation: libghostty remains the only
/// renderer in a native pane.
enum CloudTuiManualIOFrame: Equatable, Sendable {
    case snapshot(surfaceID: UInt64, columns: Int, rows: Int, bytes: Data)
    case output(surfaceID: UInt64, bytes: Data)
    case resized(surfaceID: UInt64, columns: Int, rows: Int, bytes: Data)
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
}
