import Foundation

/// Reads a local process's parent and executable, for the Kill Process
/// ownership check. The App uses ``SystemProcessLineage``; tests pass a table.
public protocol ProcessLineage {
    /// The parent pid of `pid`; nil when `pid` is not running.
    func parent(of pid: Int32) -> Int32?
    /// The executable path of `pid`; nil when it cannot be read.
    func executablePath(of pid: Int32) -> String?
}
