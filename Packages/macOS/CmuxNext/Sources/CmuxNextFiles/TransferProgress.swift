public import Foundation

/// Progress of one copy or move.
public struct TransferProgress: Sendable, Equatable {
    /// Top-level items done (copied, moved or skipped).
    public var itemsDone: Int
    /// Top-level items in the operation.
    public var itemsTotal: Int
    /// Bytes copied so far (a same-volume move counts its bytes at once).
    public var bytesDone: Int64
    /// Bytes in the operation (measured before it starts).
    public var bytesTotal: Int64
    /// The item in progress.
    public var current: URL?

    /// The fraction done, 0...1 (by bytes, by items when there are no bytes).
    public var fraction: Double {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        return itemsTotal == 0 ? 1 : Double(itemsDone) / Double(itemsTotal)
    }
}
