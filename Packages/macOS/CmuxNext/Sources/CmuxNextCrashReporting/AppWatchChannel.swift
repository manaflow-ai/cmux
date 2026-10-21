import Darwin

/// The app's side of the pipe to its out-of-process watcher (`cmux
/// __app-watch`, cmux-tui `app_watch.rs`; issue #22844).
///
/// One byte per event, one `write(2)` on a non-blocking descriptor, so every
/// call is async-signal-safe and never waits (a full pipe drops the byte):
///
/// - `crashBegan` (`C`): a crash path started (``CrashDeadline/arm()``). The
///   watcher ends the process if it still runs after its crash grace, which
///   covers the case the in-process deadline cannot: a crash reporter that
///   suspended every thread and then blocked.
/// - `hangBegan` / `hangEnded` (`H` / `h`): the main thread has not returned
///   to its run loop for the watchdog's hang threshold, or returned.
/// - `quitBegan` (`Q`): a requested quit began; the watcher no longer ends a
///   hang and does not relaunch.
enum AppWatchChannel {
    /// Hands the write end to the channel (once, at launch). The descriptor
    /// is set non-blocking and close-on-exec here.
    static func attach(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        watchDescriptor = descriptor
    }

    static var isAttached: Bool { watchDescriptor >= 0 }

    static func crashBegan() { send(0x43) } // "C"
    static func hangBegan() { send(0x48) } // "H"
    static func hangEnded() { send(0x68) } // "h"
    static func quitBegan() { send(0x51) } // "Q"

    private static func send(_ byte: UInt8) {
        let descriptor = watchDescriptor
        guard descriptor >= 0 else { return }
        var value = byte
        // concurrency-allow: one non-blocking 1-byte write to a pipe; a full pipe returns EAGAIN at once.
        _ = Darwin.write(descriptor, &value, 1)
    }
}

// One aligned 32-bit word, statically initialized to -1 (no lazy init, so a signal handler may read
// it at any time) and stored once by `attach` from the spawn task; a reader sees -1 (no watcher yet:
// the byte is dropped) or the descriptor, never a torn value on arm64 or x86_64.
// crash-allow: single aligned store once at launch; readers (signal handlers, watchdog thread) tolerate -1.
nonisolated(unsafe) private var watchDescriptor: Int32 = -1
