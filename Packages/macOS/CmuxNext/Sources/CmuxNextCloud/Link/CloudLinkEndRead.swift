public import Observation

/// The machine list read an ended Cloud app link starts (`CloudMachineSession.showEnded`, #34284).
/// A pause ends the app link before the list says paused (the idle pause, and soon the pause between
/// tool calls): a link that went down on a machine whose record does not read paused reads the list
/// at once, past the 30 s throttle, once per ended link, and reads as on its way (``confirming``,
/// `CloudMachineStageInput.linkEndConfirming`) until it answers, so a pause never flashes
/// "Disconnected". Any other end reads the list throttled (at most every 30 s).
@MainActor @Observable
public final class CloudLinkEndRead {
    /// One forced list read is learning whether a pause ended the link; false once it answers or a
    /// connect starts (the owner sets it false: a new connect is the ended link's answer).
    public var confirming = false

    public nonisolated init() {}

    /// The link ended. `dropped`: an app link that went down or was revoked, not refused
    /// (`CloudLinkError.isDrop`). `connects` is the owner's connect count now and `connectsNow` reads
    /// it later (nil once the owner is gone): only this ended link's read clears ``confirming``; a
    /// connect since then already did. `read(force)` reads the machine list (`CloudService.refresh`).
    public func ended(dropped: Bool, paused: Bool, connects: Int, connectsNow: @escaping @MainActor () -> Int?,
                      read: @escaping @MainActor (_ force: Bool) async -> Void) {
        guard dropped, !paused, !confirming else {
            // task-owner: one throttled list read; the reconcile it runs updates the machine's record
            Task { await read(false) }
            return
        }
        confirming = true
        // task-owner: one forced list read per ended link; the reconcile it runs updates the machine's record
        Task { [weak self] in
            await read(true)
            if let self, connectsNow() == connects { self.confirming = false }
        }
    }
}
