import CmuxTerminalSizing
import Foundation

/// Shared-sizing fields of a cmux-tui response (`shared-sizing-v1`).
public struct CloudTuiSizingResponse: Equatable, Sendable {
    /// The host participant id of the attached view or relay sub-view.
    public var participant: String?
    /// The size state from `get-size-state` or a mutation answer.
    public var state: TerminalSizingState?

    /// Creates the response fields.
    public init(participant: String? = nil, state: TerminalSizingState? = nil) {
        self.participant = participant
        self.state = state
    }
}

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
    /// `reason` defaults to `network` for daemons that send none; `view` names
    /// a relay sub-view (a phone behind this Mac) when only it was detached.
    case detached(surfaceID: UInt64, reason: TerminalDetachReason = .network, view: String? = nil)
    /// The host's published size state (`size-state`, `shared-sizing-v1`).
    case sizeState(surfaceID: UInt64, state: TerminalSizingState)
    case overflow(surfaceID: UInt64?)
    case response(
        requestID: UInt64,
        ok: Bool,
        lease: String?,
        capabilities: [String],
        outcome: String?,
        accepted: Bool?,
        error: String?,
        sizing: CloudTuiSizingResponse? = nil
    )
    /// Undecoded envelope for the per-machine resource multiplexer.
    case message(Data)
}
