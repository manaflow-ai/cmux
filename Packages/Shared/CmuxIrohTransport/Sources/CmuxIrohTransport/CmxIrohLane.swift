/// The independent application lane carried by one Iroh QUIC stream.
public enum CmxIrohLane: Equatable, Sendable {
    /// The authenticated request, response, and lifecycle control lane.
    case control

    /// Ordered server events resumed after the optional last applied sequence.
    case serverEvents(cursor: UInt64?)

    /// One terminal's ordered stream resumed after the optional byte cursor.
    case terminal(resourceID: CmxIrohResourceID, cursor: UInt64?)

    /// A terminal input-only lane. The host sends one empty replay envelope
    /// as a readiness baseline, then the stream carries only input frames.
    /// Render-grid sessions use this lane so keystrokes never wait on RPC
    /// settlement or compete with the authoritative output event stream.
    case terminalInput(resourceID: CmxIrohResourceID)

    /// A low-priority artifact stream resumed at an exact byte offset.
    case artifact(resourceID: CmxIrohResourceID, offset: UInt64)

    /// One simulator panel's video stream plus its return input channel.
    /// Not resumable: every attach restarts with a fresh keyframe, so the
    /// lane carries no cursor.
    case simulatorStream(resourceID: CmxIrohResourceID)
}
