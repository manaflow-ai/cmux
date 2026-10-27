public import AppKit
public import CmuxNextCompat
public import UniformTypeIdentifiers

/// Checked blocking NSWorkspace queries (``blockingCall(_:fileID:line:_:)``): each one waits for
/// LaunchServices or reads the disk, so query off the main thread. Opens and reveals use
/// NSWorkspace+Background.swift.
extension NSWorkspace {
    /// The app with `bundleIdentifier`, like `urlForApplication(withBundleIdentifier:)`, as a checked blocking call.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: The app's bundle identifier.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The app's URL, or nil.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingURLForApplication(withBundleIdentifier bundleIdentifier: String,
                                          fileID: StaticString = #fileID, line: UInt = #line) -> URL? {
        return blockingCall(.systemCall, fileID: fileID, line: line) { urlForApplication(withBundleIdentifier: bundleIdentifier) }
    }

    /// The default app for `url`, like `urlForApplication(toOpen:)`, as a checked blocking call.
    ///
    /// - Parameters:
    ///   - url: The file or URL to open.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The app's URL, or nil.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingURLForApplication(toOpen url: URL, fileID: StaticString = #fileID, line: UInt = #line) -> URL? {
        return blockingCall(.systemCall, fileID: fileID, line: line) { urlForApplication(toOpen: url) }
    }

    /// The default app for `contentType`, like `urlForApplication(toOpen:)` with a type, as a checked blocking call.
    ///
    /// - Parameters:
    ///   - contentType: The type of content to open.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The app's URL, or nil.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingURLForApplication(toOpen contentType: UTType, fileID: StaticString = #fileID, line: UInt = #line) -> URL? {
        return blockingCall(.systemCall, fileID: fileID, line: line) { urlForApplication(toOpen: contentType) }
    }

    /// Every app that opens `url`, like `urlsForApplications(toOpen:)`, as a checked blocking call.
    ///
    /// - Parameters:
    ///   - url: The file or URL to open.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The apps' URLs.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingURLsForApplications(toOpen url: URL, fileID: StaticString = #fileID, line: UInt = #line) -> [URL] {
        return blockingCall(.systemCall, fileID: fileID, line: line) { urlsForApplications(toOpen: url) }
    }

    /// Every app that opens `contentType`, like `urlsForApplications(toOpen:)` with a type, as a checked blocking call.
    ///
    /// - Parameters:
    ///   - contentType: The type of content to open.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The apps' URLs.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingURLsForApplications(toOpen contentType: UTType, fileID: StaticString = #fileID, line: UInt = #line) -> [URL] {
        return blockingCall(.systemCall, fileID: fileID, line: line) { urlsForApplications(toOpen: contentType) }
    }

    /// The icon of the file at `path`, like `icon(forFile:)`, as a checked blocking call.
    ///
    /// - Parameters:
    ///   - path: The file's path.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The icon.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingIcon(forFile path: String, fileID: StaticString = #fileID, line: UInt = #line) -> NSImage {
        return blockingCall(.systemCall, fileID: fileID, line: line) { icon(forFile: path) }
    }

    /// The icon of `contentType`, like `icon(for:)`, as a checked blocking call.
    ///
    /// - Parameters:
    ///   - contentType: The type.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The icon.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingIcon(for contentType: UTType, fileID: StaticString = #fileID, line: UInt = #line) -> NSImage {
        return blockingCall(.systemCall, fileID: fileID, line: line) { icon(for: contentType) }
    }
}
