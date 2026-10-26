import CmuxNextSignposts
import GhosttyNextKit

/// A surface's input waits for Ghostty's terminal lock as ``SignpostName/ghosttyLockWait`` events (p04-input-078):
/// the DC1 terminal STRESS bench reads their p99 from a trace.
///
/// ghostty-next parses output in 4 KiB slices and hands the lock to a waiting key between two, so a press waits
/// behind at most one slice, as Blink's HTML parser pumps its tokens in chunks and yields to waiting input between
/// two (third_party/blink/renderer/core/html/parser/html_document_parser.cc, `PumpTokenizer`'s `ShouldYield`).
/// `ghostty_surface_set_lock_wait_callback` reports each wait of 50 us or more on the thread that waited, after it
/// released the lock. The report is compiled only with `GHOSTTY_LOCK_WAIT` (`ghosttyNextKitHasLockWait` in
/// Package.swift: the pin bump that brings the export turns it on) in Debug and bench builds; elsewhere
/// ``install(on:)`` does nothing.
nonisolated struct GhosttyLockWaitSignpost {
    /// Where the events go.
    let signposter: Signposter

    /// - Parameter signposter: Where the events go (a ghostty-category handle: `OSSignposter` is an immutable handle
    ///   the log system caches per category, so a report builds one and keeps no state).
    init(signposter: Signposter = Signposter(category: .ghostty)) {
        self.signposter = signposter
    }

    /// Records one wait of `nanos`.
    func record(nanos: UInt64) {
        guard signposter.isEnabled else { return }
        signposter.event(.ghosttyLockWait, "wait_us=\(nanos / 1_000)", arg0: nanos)
    }

    /// Reports `surface`'s waits from now on. Call once, right after `ghostty_surface_new`, before the surface gets
    /// input.
    static func install(on surface: ghostty_surface_t) {
        #if GHOSTTY_LOCK_WAIT && (DEBUG || CMUX_BENCH_HOOKS)
        // SAFETY: the caller's new surface; the callback has ghostty.h's `ghostty_surface_lock_wait_cb` signature
        // and reads no userdata.
        _ = unsafe ghostty_surface_set_lock_wait_callback(surface, ghosttyLockWait, nil)
        #endif
    }
}

/// `ghostty_surface_lock_wait_cb`: any thread that waited (the main thread for input), after the lock is released.
nonisolated func ghosttyLockWait(_ userdata: UnsafeMutableRawPointer?, _ nanos: UInt64) {
    GhosttyLockWaitSignpost().record(nanos: nanos)
}
