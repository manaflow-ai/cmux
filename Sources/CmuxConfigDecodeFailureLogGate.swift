import Foundation
import os

/// Suppresses duplicate config failures while allowing a changed file to log
/// its new failure synchronously.
// SAFETY: the only mutable state is a dictionary of value-type strings guarded
// by `loggedKeysByPath`; claims never expose that state across the lock.
final class CmuxConfigDecodeFailureLogGate: @unchecked Sendable {
    // Lock carve-out: this is one short synchronous compare-and-set invoked by
    // synchronous registry loads; no mutable state is held across I/O or await.
    private let loggedKeysByPath = OSAllocatedUnfairLock(initialState: [String: Set<String>]())

    /// Claims the current revision for a path, returning false when that exact
    /// revision has already been published. Keys are retained for the process
    /// lifetime so an out-of-order load cannot make an old revision re-log.
    func claim(path: String, key: String) -> Bool {
        loggedKeysByPath.withLock { keysByPath in
            keysByPath[path, default: []].insert(key).inserted
        }
    }
}
