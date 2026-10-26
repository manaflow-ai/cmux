import CmuxNextCompat

/// The stop flag of one ``FileInfoReader/folderSize(of:)`` walk: the caller's cancel handler sets it and the
/// lane thread walking the folder reads it between items (a lane thread has no task to cancel).
final class FolderSizeStop: Sendable {
    private let flag = Atomic<Bool>(false)

    /// Asks the walk to stop.
    func set() { flag.store(true, ordering: .relaxed) }

    /// Whether ``set()`` was called.
    var isSet: Bool { flag.load(ordering: .relaxed) }
}
