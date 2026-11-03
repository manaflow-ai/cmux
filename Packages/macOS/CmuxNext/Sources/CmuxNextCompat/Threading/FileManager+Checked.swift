public import Foundation

extension FileManager {
    /// The file operations to use in cmux code instead of `FileManager.default`'s: each disk
    /// operation is a checked blocking call (``CheckedFileManager``), so one on the main thread is
    /// reported where it happens in Debug, bench and Nightly builds.
    ///
    /// ```swift
    /// if FileManager.checked.fileExists(atPath: path) { ... }
    /// ```
    @inlinable
    public static var checked: CheckedFileManager { CheckedFileManager() }
}
