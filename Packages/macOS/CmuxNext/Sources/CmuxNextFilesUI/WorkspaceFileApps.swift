public import CmuxNextFiles
public import Foundation
import AppKit
import UniformTypeIdentifiers

/// ``FileAppsProviding`` over LaunchServices (`NSWorkspace`): every app the system reports for
/// the file's type, the default first. The lookups run off the main thread (LaunchServices can
/// take tens of milliseconds on a busy Mac).
public struct WorkspaceFileApps: FileAppsProviding {
    /// The system's apps.
    public init() {}

    public func openWithList(forFileNamed name: String, isDirectory: Bool) async -> OpenWithList {
        await Task.detached(priority: .userInitiated) { Self.list(name: name, isDirectory: isDirectory) }.value
    }

    public func open(_ files: [URL], withApplicationAt app: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open(files, withApplicationAt: app, configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    /// The type LaunchServices matches apps against for `name`.
    static func contentType(name: String, isDirectory: Bool) -> UTType {
        let ext = (name as NSString).pathExtension
        if isDirectory, ext.isEmpty { return .folder }
        if ext.isEmpty { return .plainText }
        return UTType(filenameExtension: ext, conformingTo: isDirectory ? .package : .data) ?? .data
    }

    private static func list(name: String, isDirectory: Bool) -> OpenWithList {
        let type = contentType(name: name, isDirectory: isDirectory)
        let workspace = NSWorkspace.shared
        let rows = workspace.urlsForApplications(toOpen: type).map(app)
        return OpenWithList(defaultApp: workspace.urlForApplication(toOpen: type).map(app), apps: rows)
    }

    private static func app(_ url: URL) -> OpenWithApp {
        let bundle = Bundle(url: url)
        let name = FileManager.default.displayName(atPath: url.path)
        return OpenWithApp(url: url, bundleID: bundle?.bundleIdentifier,
                           name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
    }
}
