public import AppKit
public import UniformTypeIdentifiers

/// The Launch Services and icon queries of `NSWorkspace` that wait for the system: which app opens a URL or a type,
/// where an app with a bundle identifier is, and the icon of a file or a type. Each call blocks (Launch Services'
/// database, IconServices, the disk), so it runs only off the main thread and off the cooperative pool: on a
/// `BackgroundWork` system lane (`WorkspaceQueries` in CmuxNextWakeups) or, below CmuxNextWakeups, inside a
/// ``MayBlockRunner/runSystem(_:shutdown:fileID:line:_:)`` body.
///
/// Chrome does the same: `IconLoader` reads file icons on a `MayBlock` thread pool sequence and replies to the UI
/// thread (chrome/browser/icon_loader.cc), and `shell_integration::DefaultBrowserWorker` asks Launch Services for the
/// default browser on a `MayBlock` task runner (chrome/browser/shell_integration.cc).
///
/// Tests pass a fake that answers from a table and records the thread it was asked on.
public protocol WorkspaceQuerying: Sendable {
    /// The app with `bundleIdentifier`, like NSWorkspace's app lookup by bundle identifier; nil when none is installed.
    func application(withBundleIdentifier bundleIdentifier: String) -> URL?
    /// The default app for `url` (a file, or a URL by its scheme), like NSWorkspace's default app lookup.
    func defaultApplication(toOpen url: URL) -> URL?
    /// The default app for content of `type`.
    func defaultApplication(toOpen type: UTType) -> URL?
    /// Every app that opens `url`, like NSWorkspace's app list lookup.
    func applications(toOpen url: URL) -> [URL]
    /// Every app that opens content of `type`.
    func applications(toOpen type: UTType) -> [URL]
    /// The icon of the file or app at `path`, like NSWorkspace's file icon.
    func fileIcon(atPath path: String) -> NSImage
    /// The icon of `type`, like NSWorkspace's type icon.
    func typeIcon(_ type: UTType) -> NSImage
}

/// ``WorkspaceQuerying`` over the shared `NSWorkspace`, each query through its checked blocking seam
/// (NSWorkspace+Blocking.swift): in a build with the blocking detector, a query on the main thread or the pool is
/// recorded as a violation.
public nonisolated struct SystemWorkspaceQuerying: WorkspaceQuerying {
    public init() {}

    public func application(withBundleIdentifier bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.blockingURLForApplication(withBundleIdentifier: bundleIdentifier)
    }

    public func defaultApplication(toOpen url: URL) -> URL? {
        NSWorkspace.shared.blockingURLForApplication(toOpen: url)
    }

    public func defaultApplication(toOpen type: UTType) -> URL? {
        NSWorkspace.shared.blockingURLForApplication(toOpen: type)
    }

    public func applications(toOpen url: URL) -> [URL] {
        NSWorkspace.shared.blockingURLsForApplications(toOpen: url)
    }

    public func applications(toOpen type: UTType) -> [URL] {
        NSWorkspace.shared.blockingURLsForApplications(toOpen: type)
    }

    public func fileIcon(atPath path: String) -> NSImage {
        NSWorkspace.shared.blockingIcon(forFile: path)
    }

    public func typeIcon(_ type: UTType) -> NSImage {
        NSWorkspace.shared.blockingIcon(for: type)
    }
}
