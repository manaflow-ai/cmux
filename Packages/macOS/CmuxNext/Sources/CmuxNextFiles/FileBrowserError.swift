public import Foundation

/// Why a Files operation did not happen.
public enum FileBrowserError: Error, Sendable, Equatable {
    /// The folder could not be opened or read (`errno` given).
    case unreadable(URL, Int32)
    /// A name is not allowed: empty, `.`/`..`, or with `/` or NUL.
    case invalidName(String)
    /// Rename Items' Format start number is so large that an item's number does not fit in an `Int`.
    case renameNumberTooLarge
    /// An item with the name exists where the operation would put one.
    case exists(URL)
    /// The item is gone.
    case missing(URL)
    /// A file system call failed (message from the system).
    case failed(String)
    /// The person stopped the operation.
    case cancelled
}
