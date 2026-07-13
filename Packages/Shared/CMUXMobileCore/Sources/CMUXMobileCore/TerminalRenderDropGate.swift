import Foundation

/// A render-path gate that can intentionally drop terminal frames.
public enum TerminalRenderDropGate: UInt8, Sendable, Codable, CaseIterable {
    /// Output is behind a pending terminal input acknowledgement sequence.
    case pendingInputSeq = 1
    /// A terminal replay barrier is active and live output is being held back.
    case replayBarrier = 2
    /// Render-grid output is waiting for a full baseline frame.
    case baselineWait = 3
    /// A viewport resize barrier is active while geometry is being reconciled.
    case viewportBarrier = 4

    /// The bit used in compact gate-active snapshots.
    public var bit: Int {
        1 << Int(rawValue - 1)
    }
}
