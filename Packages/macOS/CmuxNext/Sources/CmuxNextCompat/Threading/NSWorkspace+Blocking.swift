public import AppKit

// Checked seams over NSWorkspace queries that wait for LaunchServices or read the disk
// (``assertBlockingAllowed(_:fileID:line:)``). Each forwards its caller's `fileID` and `line`; query off
// the main thread. Opens and reveals use NSWorkspace+Background.swift.
extension NSWorkspace {
    /// The app with `bundleIdentifier`, like `urlForApplication(withBundleIdentifier:)`, as a checked blocking call.
    ///
    /// - Returns: The app's URL, or nil.
    @inlinable
    public func blockingURLForApplication(withBundleIdentifier bundleIdentifier: String,
                                          fileID: StaticString = #fileID, line: UInt = #line) -> URL? {
        assertBlockingAllowed(.systemCall, fileID: fileID, line: line)
        return urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// The default app for `url`, like `urlForApplication(toOpen:)`, as a checked blocking call.
    ///
    /// - Returns: The app's URL, or nil.
    @inlinable
    public func blockingURLForApplication(toOpen url: URL, fileID: StaticString = #fileID, line: UInt = #line) -> URL? {
        assertBlockingAllowed(.systemCall, fileID: fileID, line: line)
        return urlForApplication(toOpen: url)
    }

    /// Every app that opens `url`, like `urlsForApplications(toOpen:)`, as a checked blocking call.
    ///
    /// - Returns: The apps' URLs.
    @inlinable
    public func blockingURLsForApplications(toOpen url: URL, fileID: StaticString = #fileID, line: UInt = #line) -> [URL] {
        assertBlockingAllowed(.systemCall, fileID: fileID, line: line)
        return urlsForApplications(toOpen: url)
    }

    /// The icon of the file at `path`, like `icon(forFile:)`, as a checked blocking call.
    ///
    /// - Returns: The icon.
    @inlinable
    public func blockingIcon(forFile path: String, fileID: StaticString = #fileID, line: UInt = #line) -> NSImage {
        assertBlockingAllowed(.systemCall, fileID: fileID, line: line)
        return icon(forFile: path)
    }
}
