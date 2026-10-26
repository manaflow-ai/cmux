import CmuxNextCompat

/// The stop flag of one long lane item (a ``FileInfoReader/folderSize(of:)`` walk, a transfer's copy): the
/// caller's cancel handler sets it and the lane thread doing the work reads it between items or blocks (a lane
/// thread has no task to cancel).
final class FileWorkStop: Sendable {
    private let flag = Atomic<Bool>(false)

    /// Asks the work to stop.
    func set() { flag.store(true, ordering: .relaxed) }

    /// Whether ``set()`` was called.
    var isSet: Bool { flag.load(ordering: .relaxed) }
}
