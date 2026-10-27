public import CmuxNextFiles
public import CmuxNextWakeups
public import AppKit
public import Foundation
import CmuxNextCompatAppKit
public import UniformTypeIdentifiers

/// ``FileAppsProviding`` over Launch Services: every app the system reports for the file's type, the default
/// first. The list, the apps' names included, is asked on the system lane and kept per type in the app's
/// ``WorkspaceQueries``, so an Open With submenu for a type seen before fills from the kept list in its first turn.
public nonisolated struct WorkspaceFileApps: FileAppsProviding {
    private let queries: WorkspaceQueries

    /// The system's apps, asked through `queries`.
    public init(queries: WorkspaceQueries) {
        self.queries = queries
    }

    public func openWithList(forFileNamed name: String, isDirectory: Bool) async -> OpenWithList {
        let query = Self.query(Self.contentType(name: name, isDirectory: isDirectory))
        guard let list = try? await queries.value(query, priority: .userBlocking) else { return OpenWithList(defaultApp: nil, apps: []) }
        await queries.prefetch(list.apps.map { WorkspaceQuery<NSImage>.fileIcon(atPath: $0.url.path, side: Self.iconSide) }, priority: .userVisible)
        return list
    }

    @MainActor public func keptOpenWithList(forFileNamed name: String, isDirectory: Bool) -> OpenWithList? {
        queries.cached(Self.query(Self.contentType(name: name, isDirectory: isDirectory)))
    }

    /// Warms the Open With lists of the types of `items`, distinct types only, at best effort.
    @MainActor public func prefetchOpenWithLists(for items: [(name: String, isDirectory: Bool)]) {
        var types = Set<UTType>()
        for item in items { types.insert(Self.contentType(name: item.name, isDirectory: item.isDirectory)) }
        queries.prefetch(types.map(Self.query), priority: .bestEffort)
    }

    /// Sets `item`'s image to `app`'s icon at the menu's size, now when it is kept, else when it arrives.
    @MainActor public func showIcon(of app: URL, in item: NSMenuItem) {
        queries.image(WorkspaceQuery<NSImage>.fileIcon(atPath: app.path, side: Self.iconSide), into: item)
    }

    /// An Open With row's icon side, in points.
    static let iconSide: CGFloat = 16

    public func open(_ files: [URL], withApplicationAt app: URL) async -> Bool {
        await NSWorkspace.shared.openedInBackground(files, withApplicationAt: app)
    }

    /// The Open With list of `type`, kept per type.
    static func query(_ type: UTType) -> WorkspaceQuery<OpenWithList> {
        WorkspaceQuery(id: "files.openWith." + type.identifier, refreshes: true) { system in
            let rows = system.applications(toOpen: type).map(Self.app)
            return OpenWithList(defaultApp: system.defaultApplication(toOpen: type).map(Self.app), apps: rows)
        }
    }

    /// The type Launch Services matches apps against for `name`.
    static func contentType(name: String, isDirectory: Bool) -> UTType {
        let ext = (name as NSString).pathExtension
        if isDirectory, ext.isEmpty { return .folder }
        if ext.isEmpty { return .plainText }
        return UTType(filenameExtension: ext, conformingTo: isDirectory ? .package : .data) ?? .data
    }

    /// One row: the bundle's identifier and Finder's name (both read from disk, on the system lane).
    private static func app(_ url: URL) -> OpenWithApp {
        let bundle = Bundle(url: url)
        let name = FileManager.default.displayName(atPath: url.path)
        return OpenWithApp(url: url, bundleID: bundle?.bundleIdentifier,
                           name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
    }
}
