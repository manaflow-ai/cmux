public import Foundation

/// The file operations of `FileManager.default` as checked blocking calls: in Debug, bench and Nightly
/// builds each one reports a main-thread call (``blockingCall(_:fileID:line:_:)``) at the
/// code that called it; in Release each is the `FileManager` call alone. Get it from
/// ``Foundation/FileManager/checked``; the method names and labels are `FileManager`'s, plus the
/// call-site arguments.
///
/// Every method takes `FileManager`'s parameters (documented there) plus `fileID` and `line`, the
/// calling code's `#fileID` and `#line`, which name the call site; it returns and throws what the
/// `FileManager` method does. `homeDirectoryForCurrentUser`, `temporaryDirectory` and
/// `urls(for:in:)` do not touch the disk and stay on `FileManager.default`.
///
/// ```swift
/// if FileManager.checked.fileExists(atPath: path) { ... }
/// ```
public struct CheckedFileManager: Sendable {
    /// Makes the value (use ``Foundation/FileManager/checked``).
    @inlinable
    public init() {}

    /// Whether a file or folder exists at `path`. Like `FileManager.fileExists`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func fileExists(atPath path: String, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        return blockingCall(.fileIO, fileID: fileID, line: line) { FileManager.default.fileExists(atPath: path) }
    }

    /// Whether a file or folder exists at `path`, and whether it is a folder. Like `FileManager.fileExists`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        // SAFETY: forwards the caller's pointer to fileExists unchanged, only for the call; the caller's own `unsafe`
        // states why it is valid for it.
        return blockingCall(.fileIO, fileID: fileID, line: line) { unsafe FileManager.default.fileExists(atPath: path, isDirectory: isDirectory) }
    }

    /// Whether the file at `path` is readable. Like `FileManager.isReadableFile`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func isReadableFile(atPath path: String, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        return blockingCall(.fileIO, fileID: fileID, line: line) { FileManager.default.isReadableFile(atPath: path) }
    }

    /// Whether the file at `path` is writable. Like `FileManager.isWritableFile`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func isWritableFile(atPath path: String, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        return blockingCall(.fileIO, fileID: fileID, line: line) { FileManager.default.isWritableFile(atPath: path) }
    }

    /// Whether the file at `path` is executable. Like `FileManager.isExecutableFile`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func isExecutableFile(atPath path: String, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        return blockingCall(.fileIO, fileID: fileID, line: line) { FileManager.default.isExecutableFile(atPath: path) }
    }

    /// Makes a folder. Like `FileManager.createDirectory`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]? = nil, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes) }
    }

    /// Makes a folder. Like `FileManager.createDirectory`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func createDirectory(atPath path: String, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]? = nil, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: createIntermediates, attributes: attributes) }
    }

    /// Removes a file or folder. Like `FileManager.removeItem`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func removeItem(at url: URL, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.removeItem(at: url) }
    }

    /// Removes a file or folder. Like `FileManager.removeItem`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func removeItem(atPath path: String, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.removeItem(atPath: path) }
    }

    /// Lists a folder. Like `FileManager.contentsOfDirectory`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions = [], fileID: StaticString = #fileID, line: UInt = #line) throws -> [URL] {
        return try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask) }
    }

    /// Lists a folder. Like `FileManager.contentsOfDirectory`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func contentsOfDirectory(atPath path: String, fileID: StaticString = #fileID, line: UInt = #line) throws -> [String] {
        return try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.contentsOfDirectory(atPath: path) }
    }

    /// Lists a folder and every folder in it. Like `FileManager.subpathsOfDirectory`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func subpathsOfDirectory(atPath path: String, fileID: StaticString = #fileID, line: UInt = #line) throws -> [String] {
        return try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.subpathsOfDirectory(atPath: path) }
    }

    /// Starts a folder walk. Only the start is checked: each `nextObject()` reads the disk too, so walk off the main thread. Like `FileManager.enumerator`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions = [], errorHandler handler: ((URL, any Error) -> Bool)? = nil, fileID: StaticString = #fileID, line: UInt = #line) -> FileManager.DirectoryEnumerator? {
        return blockingCall(.fileIO, fileID: fileID, line: line) { FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: mask, errorHandler: handler) }
    }

    /// Writes a file. Like `FileManager.createFile`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable @discardableResult
    public func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        return blockingCall(.fileIO, fileID: fileID, line: line) { FileManager.default.createFile(atPath: path, contents: data, attributes: attr) }
    }

    /// Reads a file. Like `FileManager.contents`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func contents(atPath path: String, fileID: StaticString = #fileID, line: UInt = #line) -> Data? {
        return blockingCall(.fileIO, fileID: fileID, line: line) { FileManager.default.contents(atPath: path) }
    }

    /// Whether two files have the same contents. Like `FileManager.contentsEqual`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func contentsEqual(atPath path1: String, andPath path2: String, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        return blockingCall(.fileIO, fileID: fileID, line: line) { FileManager.default.contentsEqual(atPath: path1, andPath: path2) }
    }

    /// A file's attributes. Like `FileManager.attributesOfItem`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func attributesOfItem(atPath path: String, fileID: StaticString = #fileID, line: UInt = #line) throws -> [FileAttributeKey: Any] {
        return try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.attributesOfItem(atPath: path) }
    }

    /// A volume's attributes. Like `FileManager.attributesOfFileSystem`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func attributesOfFileSystem(forPath path: String, fileID: StaticString = #fileID, line: UInt = #line) throws -> [FileAttributeKey: Any] {
        return try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.attributesOfFileSystem(forPath: path) }
    }

    /// Changes a file's attributes. Like `FileManager.setAttributes`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.setAttributes(attributes, ofItemAtPath: path) }
    }

    /// Moves a file or folder. Like `FileManager.moveItem`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func moveItem(at srcURL: URL, to dstURL: URL, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.moveItem(at: srcURL, to: dstURL) }
    }

    /// Moves a file or folder. Like `FileManager.moveItem`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func moveItem(atPath srcPath: String, toPath dstPath: String, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.moveItem(atPath: srcPath, toPath: dstPath) }
    }

    /// Copies a file or folder. Like `FileManager.copyItem`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func copyItem(at srcURL: URL, to dstURL: URL, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.copyItem(at: srcURL, to: dstURL) }
    }

    /// Copies a file or folder. Like `FileManager.copyItem`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func copyItem(atPath srcPath: String, toPath dstPath: String, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.copyItem(atPath: srcPath, toPath: dstPath) }
    }

    /// Hard-links a file. Like `FileManager.linkItem`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func linkItem(at srcURL: URL, to dstURL: URL, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.linkItem(at: srcURL, to: dstURL) }
    }

    /// Replaces a file with another, atomically. Like `FileManager.replaceItemAt`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable @discardableResult
    public func replaceItemAt(_ originalItemURL: URL, withItemAt newItemURL: URL, backupItemName: String? = nil, options: FileManager.ItemReplacementOptions = [], fileID: StaticString = #fileID, line: UInt = #line) throws -> URL? {
        return try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.replaceItemAt(originalItemURL, withItemAt: newItemURL, backupItemName: backupItemName, options: options) }
    }

    /// Where a symbolic link points. Like `FileManager.destinationOfSymbolicLink`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func destinationOfSymbolicLink(atPath path: String, fileID: StaticString = #fileID, line: UInt = #line) throws -> String {
        return try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.destinationOfSymbolicLink(atPath: path) }
    }

    /// Makes a symbolic link. Like `FileManager.createSymbolicLink`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func createSymbolicLink(at url: URL, withDestinationURL destURL: URL, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destURL) }
    }

    /// Makes a symbolic link. Like `FileManager.createSymbolicLink`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func createSymbolicLink(atPath path: String, withDestinationPath destPath: String, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destPath) }
    }

    /// Moves a file or folder to the Trash. Like `FileManager.trashItem`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>? = nil, fileID: StaticString = #fileID, line: UInt = #line) throws {
        // SAFETY: forwards the caller's result pointer to trashItem unchanged, only for the call; the caller's own
        // `unsafe` states why it is valid for it (nil writes nothing).
        try blockingCall(.fileIO, fileID: fileID, line: line) { try unsafe FileManager.default.trashItem(at: url, resultingItemURL: outResultingURL) }
    }

    /// Finds (and with `create`, makes) a system folder such as Application Support. Like `FileManager.url`, checked.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func url(for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask, appropriateFor url: URL? = nil, create shouldCreate: Bool = false, fileID: StaticString = #fileID, line: UInt = #line) throws -> URL {
        return try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.url(for: directory, in: domain, appropriateFor: url, create: shouldCreate) }
    }
}
