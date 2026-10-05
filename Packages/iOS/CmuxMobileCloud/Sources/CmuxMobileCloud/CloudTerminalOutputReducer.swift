public import Foundation

/// Turns link output events into the calls an embedding emulator needs.
///
/// The phone's emulator has no reset API, so a re-snapshot (after a link
/// resync) is preceded by RIS (`ESC c`) bytes. The first snapshot into a
/// fresh emulator needs no reset.
public struct CloudTerminalOutputReducer: Sendable, Equatable {
    /// What the emulator should do for one event.
    public enum Action: Sendable, Equatable {
        /// Pin the emulator grid to `cols` x `rows`.
        case applyGrid(cols: Int, rows: Int)
        /// Feed these bytes to the emulator.
        case write(Data)
        /// The terminal ended; show that and stop accepting input.
        case exited
    }

    /// RIS: full terminal reset.
    public static let resetSequence = Data([0x1B, 0x63])

    private var snapshotsSeen = 0

    /// Creates a reducer for a fresh emulator.
    public init() {}

    /// The actions for `event`, in order.
    public mutating func reduce(_ event: CloudTerminalOutputEvent) -> [Action] {
        switch event {
        case .snapshot(let replay, let cols, let rows):
            defer { snapshotsSeen += 1 }
            var actions: [Action] = []
            if cols > 0, rows > 0 { actions.append(.applyGrid(cols: cols, rows: rows)) }
            var bytes = Data()
            if snapshotsSeen > 0 { bytes.append(Self.resetSequence) }
            bytes.append(replay)
            if !bytes.isEmpty { actions.append(.write(bytes)) }
            return actions
        case .output(let data):
            return data.isEmpty ? [] : [.write(data)]
        case .resized(let cols, let rows):
            guard cols > 0, rows > 0 else { return [] }
            return [.applyGrid(cols: cols, rows: rows)]
        case .exited:
            return [.exited]
        }
    }
}
