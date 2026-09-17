import Foundation

/// A live process with an open descriptor for the inspected lock inode.
///
/// An open descriptor alone does not prove ownership. Callers also require an
/// active lock and exactly one holder before offering a continuation target.
public struct CodexWriterOwner: Equatable, Sendable {
    /// Kernel PID identifying the holder.
    public let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    /// Executable path for diagnostics, never used to find a session.
    public let executable: String
    /// Current kernel cwd, when readable.
    public let workingDirectory: String?
    /// Live kernel controlling-terminal device, independent of reported tty names.
    public let ttyDevice: Int64?
    /// Current ancestors up to the terminal foreground process.
    public let ancestorPIDs: Set<Int32>
}
