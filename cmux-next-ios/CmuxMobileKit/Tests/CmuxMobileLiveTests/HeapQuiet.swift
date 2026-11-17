import Darwin
import Foundation

/// Keeps the kit's heap measurements and its heap-heavy proofs apart.
///
/// `FeedSpillTests.memoryWithSpill` and `AgentChatSpillTests.memoryStaysFlatWithTheWindow` read
/// malloc's bytes in use for the whole process, before and after their store fills. The hybrid
/// proofs (`AgentCLIHybridProofTests`) load the parity fixtures and replay thousands of frames on
/// their own thread; any of that between the two reads counted as the store's own bytes. So a
/// measurement holds this lock exclusively, and each proof holds it shared: the proofs still run
/// side by side, and no proof runs while a measurement reads the heap.
///
/// `swift test` runs every test target in one process, so the two targets that measure share one
/// lock through `flock` on a file named for this process: each `acquire` opens the file anew, and
/// on Darwin `flock` locks of different opens of one file exclude each other. A copy of this file
/// is in `CmuxMobileLiveTests` and `CmuxMobileAgentChatTests`; keep them the same.
enum HeapQuiet {
    /// One held lock. `release` once.
    struct Hold: Sendable {
        let descriptor: Int32
        func release() {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    static var path: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("cmux-mobilekit-heap-quiet-\(getpid()).lock")
    }

    /// For a heap measurement: waits, off the caller's thread, until no proof runs.
    static func measuring() async -> Hold {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                // A blocking lock without `LOCK_NB` returns only with the lock held or on a signal.
                continuation.resume(returning: acquire(LOCK_EX, at: path)!)
            }
            thread.name = "HeapQuiet"
            thread.start()
        }
    }

    /// For heap-heavy work on a thread of its own (blocks that thread): waits until no
    /// measurement runs.
    static func allocatingOnThisThread() -> Hold {
        acquire(LOCK_SH, at: path)!
    }

    /// `flock(operation)` on a new open of `path`: nil only when `operation` has `LOCK_NB` and
    /// another open holds a lock that excludes it.
    static func acquire(_ operation: Int32, at path: String) -> Hold? {
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        precondition(descriptor >= 0, "HeapQuiet: open \(path): errno \(errno)")
        while flock(descriptor, operation) != 0 {
            if errno == EINTR { continue }
            precondition(errno == EWOULDBLOCK, "HeapQuiet: flock: errno \(errno)")
            close(descriptor)
            return nil
        }
        return Hold(descriptor: descriptor)
    }
}
