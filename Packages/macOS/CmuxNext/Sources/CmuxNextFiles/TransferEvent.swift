public import Foundation

/// An event of a running copy or move.
public enum TransferEvent: Sendable, Equatable {
    /// More is done.
    case progress(TransferProgress)
    /// The operation ended. `placed` maps each source to where it now is
    /// (skipped items are absent); `replaced` lists items moved to the Trash by Replace.
    case finished(placed: [URL: URL], replaced: [TrashedItem])
}
