public import Foundation
import Synchronization
import os

public enum TerminalChannelCloseReason: Sendable, Hashable {
    /// `detach()` was called.
    case detachedByClient
    /// The surface disappeared or its output tap stopped.
    case surfaceGone
    /// This view fell behind; reattach.
    case overflow
    case connectionLost(String)
}

/// Ordered stream for one attached terminal view:
/// `(replay | snapshot) -> (output | resized | snapshot | colorsChanged | scrollChanged)* -> closed`.
public enum TerminalChannelEvent: Sendable, Hashable {
    /// Initial snapshot. Feed into a fresh surface before any output.
    case replay(TerminalReplay)
    /// GHOSTSNP snapshot of a snapshot attach: a `ready` frame replaces the
    /// terminal state in place (it is also the grid change: a snapshot
    /// attach gets no `resized`); `history` frames add its scrollback.
    case snapshot(TerminalSnapshotFrame)
    /// Live PTY bytes in order. Apply `colors` with this chunk when present.
    case output(Data, colors: TerminalColors?)
    /// Canonical size changed: discard the mirror and rebuild from this replay
    /// before later output.
    case resized(TerminalReplay)
    case colorsChanged(TerminalColors)
    case scrollChanged(offset: UInt64, atBottom: Bool)
    case closed(TerminalChannelCloseReason)
}

/// What the terminal view module consumes. It never imports the daemon's
/// wire types beyond these.
public protocol TerminalByteChannel: Sendable {
    var events: AsyncStream<TerminalChannelEvent> { get }
    /// Writes encoded input (keys, mouse, focus, paste) as produced by Ghostty.
    func write(_ data: Data) async
    /// Reports this view's grid. Pixel sizes are for future render protocols.
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async
}
