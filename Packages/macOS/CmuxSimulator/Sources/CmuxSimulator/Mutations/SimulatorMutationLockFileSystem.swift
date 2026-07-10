import Foundation

/// Filesystem and advisory-lock operations used by ``SimulatorMutationGate``.
package protocol SimulatorMutationLockFileSystem: Sendable {
    /// Returns the user-private directory shared by host and worker processes.
    var defaultLockDirectory: URL { get }
    /// Creates or validates the private lock directory.
    func prepareLockDirectory(_ directory: URL) throws
    /// Opens one regular lock file without allowing descriptor inheritance.
    func openLockFile(_ url: URL) throws -> Int32
    /// Blocks the calling helper thread until it owns an exclusive advisory lock.
    func lock(_ descriptor: Int32) throws
    /// Releases an acquired advisory lock.
    func unlock(_ descriptor: Int32)
    /// Closes an open lock descriptor.
    func close(_ descriptor: Int32)
}
