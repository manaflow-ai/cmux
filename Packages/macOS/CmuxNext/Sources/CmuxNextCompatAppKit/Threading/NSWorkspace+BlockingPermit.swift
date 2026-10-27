public import AppKit
public import CmuxNextCompat
public import UniformTypeIdentifiers

extension NSWorkspace {
    /// ``blockingURLForApplication(withBundleIdentifier:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingURLForApplication(withBundleIdentifier bundleIdentifier: String,
                                          _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> URL? {
        return blockingCall(.systemCall, permit, fileID: fileID, line: line) { urlForApplication(withBundleIdentifier: bundleIdentifier) }
    }

    /// ``blockingURLForApplication(toOpen:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingURLForApplication(toOpen url: URL, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> URL? {
        return blockingCall(.systemCall, permit, fileID: fileID, line: line) { urlForApplication(toOpen: url) }
    }

    /// ``blockingURLForApplication(toOpen:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingURLForApplication(toOpen contentType: UTType, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> URL? {
        return blockingCall(.systemCall, permit, fileID: fileID, line: line) { urlForApplication(toOpen: contentType) }
    }

    /// ``blockingURLsForApplications(toOpen:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingURLsForApplications(toOpen url: URL, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> [URL] {
        return blockingCall(.systemCall, permit, fileID: fileID, line: line) { urlsForApplications(toOpen: url) }
    }

    /// ``blockingURLsForApplications(toOpen:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingURLsForApplications(toOpen contentType: UTType, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> [URL] {
        return blockingCall(.systemCall, permit, fileID: fileID, line: line) { urlsForApplications(toOpen: contentType) }
    }

    /// ``blockingIcon(forFile:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingIcon(forFile path: String, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> NSImage {
        return blockingCall(.systemCall, permit, fileID: fileID, line: line) { icon(forFile: path) }
    }

    /// ``blockingIcon(for:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingIcon(for contentType: UTType, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> NSImage {
        return blockingCall(.systemCall, permit, fileID: fileID, line: line) { icon(for: contentType) }
    }
}
