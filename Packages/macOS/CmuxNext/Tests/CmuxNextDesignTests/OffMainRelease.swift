import Foundation

/// Drops the only reference to the object `make` returns on a background thread, then returns on
/// the main actor after the main queue ran everything the deinit queued there.
///
/// The object is retained once, unmanaged, before `make`'s own reference goes at the end of the
/// statement, so the background release is the last one and the deinit runs off main. A deinit
/// hands its main-thread work to the main queue (`MainDelivery`, `DispatchQueue.main.async`) before
/// the release returns; this then queues the resume on the same serial queue from the same thread,
/// so the resume runs after that work and the caller checks the result with no wait.
@MainActor
func releaseOffMain(_ make: () -> AnyObject) async {
    let bits = UInt(bitPattern: Unmanaged.passRetained(make()).toOpaque())
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        Thread.detachNewThread {
            if let pointer = UnsafeRawPointer(bitPattern: bits) { Unmanaged<AnyObject>.fromOpaque(pointer).release() }
            // main-async-allow: the barrier is the main queue itself, FIFO after the deinit's own hop
            DispatchQueue.main.async { done.resume() }
        }
    }
}
