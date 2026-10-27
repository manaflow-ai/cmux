import CmuxNextCompat

/// An object given once from any thread and kept for the process, read from any thread with one acquiring load and
/// no reference-count traffic (``withObject(_:)``). Only the first ``install(_:)`` keeps its object; a later one is
/// released at once, since nothing saw it. The trace hook's ``GhosttyTraceHook/Recorder`` holds its app seams in
/// these, since Ghostty's threads read them while the app gives them.
nonisolated final class ProcessOnceSlot<Object: AnyObject & Sendable>: Sendable {
    /// The address of the retained object, 0 until one is installed.
    private let address = Atomic<UInt64>(0)

    /// Keeps `object` for the process unless one is installed already.
    func install(_ object: Object) {
        // SAFETY: one retain, kept for the process once its address is stored (`address`), else released
        // at once below, since nothing else saw it.
        let retained = unsafe Unmanaged.passRetained(object)
        // SAFETY: as above; the address is only stored, as an integer.
        let bits = unsafe UInt64(UInt(bitPattern: retained.toOpaque()))
        if !address.compareExchange(expected: 0, desired: bits, ordering: .acquiringAndReleasing).exchanged {
            // SAFETY: as above.
            unsafe retained.release()
        }
    }

    /// Whether an object is installed.
    var isInstalled: Bool { address.load(ordering: .acquiring) != 0 }

    /// Runs `body` with the installed object, borrowed; nothing before an install.
    func withObject(_ body: (Object) -> Void) {
        // SAFETY: a nonzero address is the object `install` retained for the process and never releases,
        // so it is live; it is borrowed only for `body`.
        guard let raw = unsafe UnsafeRawPointer(bitPattern: UInt(address.load(ordering: .acquiring))) else { return }
        // SAFETY: as above.
        unsafe Unmanaged<Object>.fromOpaque(raw)._withUnsafeGuaranteedRef(body)
    }
}
