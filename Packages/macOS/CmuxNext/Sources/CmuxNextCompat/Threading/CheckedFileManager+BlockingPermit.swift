public import Foundation

extension CheckedFileManager {
    /// ``fileExists(atPath:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func fileExists(atPath path: String, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        return blockingCall(.fileIO, permit, fileID: fileID, line: line) { FileManager.default.fileExists(atPath: path) }
    }

    /// ``fileExists(atPath:isDirectory:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        // SAFETY: forwards the caller's pointer to fileExists unchanged, only for the call; the caller's own `unsafe`
        // states why it is valid for it.
        return blockingCall(.fileIO, permit, fileID: fileID, line: line) { unsafe FileManager.default.fileExists(atPath: path, isDirectory: isDirectory) }
    }

    /// ``isReadableFile(atPath:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func isReadableFile(atPath path: String, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        return blockingCall(.fileIO, permit, fileID: fileID, line: line) { FileManager.default.isReadableFile(atPath: path) }
    }

    /// ``isWritableFile(atPath:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func isWritableFile(atPath path: String, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        return blockingCall(.fileIO, permit, fileID: fileID, line: line) { FileManager.default.isWritableFile(atPath: path) }
    }

    /// ``isExecutableFile(atPath:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func isExecutableFile(atPath path: String, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        return blockingCall(.fileIO, permit, fileID: fileID, line: line) { FileManager.default.isExecutableFile(atPath: path) }
    }

    /// ``createDirectory(at:withIntermediateDirectories:attributes:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, _ permit: borrowing BlockingPermit, attributes: [FileAttributeKey: Any]? = nil, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes) }
    }

    /// ``createDirectory(atPath:withIntermediateDirectories:attributes:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func createDirectory(atPath path: String, withIntermediateDirectories createIntermediates: Bool, _ permit: borrowing BlockingPermit, attributes: [FileAttributeKey: Any]? = nil, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: createIntermediates, attributes: attributes) }
    }

    /// ``removeItem(at:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func removeItem(at url: URL, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.removeItem(at: url) }
    }

    /// ``removeItem(atPath:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func removeItem(atPath path: String, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.removeItem(atPath: path) }
    }

    /// ``contentsOfDirectory(at:includingPropertiesForKeys:options:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, _ permit: borrowing BlockingPermit, options mask: FileManager.DirectoryEnumerationOptions = [], fileID: StaticString = #fileID, line: UInt = #line) throws -> [URL] {
        return try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask) }
    }

    /// ``contentsOfDirectory(atPath:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func contentsOfDirectory(atPath path: String, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws -> [String] {
        return try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.contentsOfDirectory(atPath: path) }
    }

    /// ``subpathsOfDirectory(atPath:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func subpathsOfDirectory(atPath path: String, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws -> [String] {
        return try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.subpathsOfDirectory(atPath: path) }
    }

    /// ``enumerator(at:includingPropertiesForKeys:options:errorHandler:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, _ permit: borrowing BlockingPermit, options mask: FileManager.DirectoryEnumerationOptions = [], errorHandler handler: ((URL, any Error) -> Bool)? = nil, fileID: StaticString = #fileID, line: UInt = #line) -> FileManager.DirectoryEnumerator? {
        return blockingCall(.fileIO, permit, fileID: fileID, line: line) { FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: mask, errorHandler: handler) }
    }

    /// ``createFile(atPath:contents:attributes:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable @discardableResult
    public func createFile(atPath path: String, contents data: Data?, _ permit: borrowing BlockingPermit, attributes attr: [FileAttributeKey: Any]? = nil, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        return blockingCall(.fileIO, permit, fileID: fileID, line: line) { FileManager.default.createFile(atPath: path, contents: data, attributes: attr) }
    }

    /// ``contents(atPath:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func contents(atPath path: String, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Data? {
        return blockingCall(.fileIO, permit, fileID: fileID, line: line) { FileManager.default.contents(atPath: path) }
    }

    /// ``contentsEqual(atPath:andPath:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func contentsEqual(atPath path1: String, andPath path2: String, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        return blockingCall(.fileIO, permit, fileID: fileID, line: line) { FileManager.default.contentsEqual(atPath: path1, andPath: path2) }
    }

    /// ``attributesOfItem(atPath:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func attributesOfItem(atPath path: String, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws -> [FileAttributeKey: Any] {
        return try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.attributesOfItem(atPath: path) }
    }

    /// ``attributesOfFileSystem(forPath:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func attributesOfFileSystem(forPath path: String, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws -> [FileAttributeKey: Any] {
        return try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.attributesOfFileSystem(forPath: path) }
    }

    /// ``setAttributes(_:ofItemAtPath:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.setAttributes(attributes, ofItemAtPath: path) }
    }

    /// ``moveItem(at:to:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func moveItem(at srcURL: URL, to dstURL: URL, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.moveItem(at: srcURL, to: dstURL) }
    }

    /// ``moveItem(atPath:toPath:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func moveItem(atPath srcPath: String, toPath dstPath: String, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.moveItem(atPath: srcPath, toPath: dstPath) }
    }

    /// ``copyItem(at:to:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func copyItem(at srcURL: URL, to dstURL: URL, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.copyItem(at: srcURL, to: dstURL) }
    }

    /// ``copyItem(atPath:toPath:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func copyItem(atPath srcPath: String, toPath dstPath: String, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.copyItem(atPath: srcPath, toPath: dstPath) }
    }

    /// ``linkItem(at:to:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func linkItem(at srcURL: URL, to dstURL: URL, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.linkItem(at: srcURL, to: dstURL) }
    }

    /// ``replaceItemAt(_:withItemAt:backupItemName:options:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable @discardableResult
    public func replaceItemAt(_ originalItemURL: URL, withItemAt newItemURL: URL, _ permit: borrowing BlockingPermit, backupItemName: String? = nil, options: FileManager.ItemReplacementOptions = [], fileID: StaticString = #fileID, line: UInt = #line) throws -> URL? {
        return try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.replaceItemAt(originalItemURL, withItemAt: newItemURL, backupItemName: backupItemName, options: options) }
    }

    /// ``destinationOfSymbolicLink(atPath:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func destinationOfSymbolicLink(atPath path: String, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws -> String {
        return try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.destinationOfSymbolicLink(atPath: path) }
    }

    /// ``createSymbolicLink(at:withDestinationURL:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func createSymbolicLink(at url: URL, withDestinationURL destURL: URL, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destURL) }
    }

    /// ``createSymbolicLink(atPath:withDestinationPath:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func createSymbolicLink(atPath path: String, withDestinationPath destPath: String, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destPath) }
    }

    /// ``trashItem(at:resultingItemURL:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func trashItem(at url: URL, _ permit: borrowing BlockingPermit, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>? = nil, fileID: StaticString = #fileID, line: UInt = #line) throws {
        // SAFETY: forwards the caller's result pointer to trashItem unchanged, only for the call; the caller's own
        // `unsafe` states why it is valid for it (nil writes nothing).
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try unsafe FileManager.default.trashItem(at: url, resultingItemURL: outResultingURL) }
    }

    /// ``url(for:in:appropriateFor:create:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func url(for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask, _ permit: borrowing BlockingPermit, appropriateFor url: URL? = nil, create shouldCreate: Bool = false, fileID: StaticString = #fileID, line: UInt = #line) throws -> URL {
        return try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileManager.default.url(for: directory, in: domain, appropriateFor: url, create: shouldCreate) }
    }
}
