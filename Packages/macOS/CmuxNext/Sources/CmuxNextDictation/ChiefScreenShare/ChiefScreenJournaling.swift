public import Foundation

/// Where a sharing session keeps what the Chief saw. ``ChiefScreenJournal`` is the real one.
public protocol ChiefScreenJournaling: Sendable {
    /// Sharing started: ``record(_:at:remember:)`` writes from now on.
    func beginSharing() async

    /// Sharing stopped: the current-screen files are deleted and later records write nothing.
    /// Remembered frames and inbox entries stay (they are the memory's source).
    func endSharing() async

    /// Keeps `frame` as the current screen, and when `remember` is true as a memory entry too.
    ///
    /// - Parameters:
    ///   - frame: The frame.
    ///   - at: When it was taken.
    ///   - remember: Also write its source frame and an inbox entry for the Chief's memory.
    /// - Returns: The observation written, nil when sharing is off or the disk refused it.
    func record(_ frame: ChiefScreenFrame, at: Date, remember: Bool) async -> ChiefScreenObservation?
}
