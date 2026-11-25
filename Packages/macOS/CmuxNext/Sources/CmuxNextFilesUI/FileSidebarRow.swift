import AppKit
import CmuxNextFiles

/// One sidebar row, as a value the sidebar view can compare and redraw.
enum FileSidebarRow: Equatable {
    /// A section title ("Favorites", "Locations").
    case header(String)
    /// A Favorite folder: its URL, display name and SF Symbol.
    case favorite(URL, name: String, symbol: String)
    /// A mounted volume and its SF Symbol.
    case volume(SidebarVolume, symbol: String)

    /// Where clicking the row goes (nil for headers).
    var url: URL? {
        switch self {
        case .header: nil
        case .favorite(let url, _, _): url
        case .volume(let volume, _): volume.url
        }
    }

    /// The rows for `sidebar`'s current state, with Finder's symbols for well-known folders.
    @MainActor
    static func rows(for sidebar: SidebarModel, home: URL) -> [FileSidebarRow] {
        let symbols: [String: String] = [
            GoPlace.applications.url(home: home).path: "app.dashed",
            GoPlace.desktop.url(home: home).path: "menubar.dock.rectangle",
            GoPlace.documents.url(home: home).path: "doc",
            GoPlace.downloads.url(home: home).path: "arrow.down.circle",
            GoPlace.iCloudDrive.url(home: home).path: "icloud",
            home.path: "house",
        ]
        var rows: [FileSidebarRow] = [.header(FilesStrings.favorites)]
        for url in sidebar.favorites {
            let name = FileManager.default.displayName(atPath: url.path)
            rows.append(.favorite(url, name: name, symbol: symbols[url.standardizedFileURL.path] ?? "folder"))
        }
        rows.append(.header(FilesStrings.locations))
        for volume in sidebar.locations {
            rows.append(.volume(volume, symbol: volume.url.path == "/" ? "internaldrive" : volume.isEjectable ? "externaldrive" : "internaldrive"))
        }
        return rows
    }
}

/// What the sidebar asks its pane to do.
struct FileSidebarActions {
    /// Show this folder.
    var open: (URL) -> Void
    /// Add (or move) a Favorite to this index.
    var add: (URL, Int) -> Void
    /// Remove a Favorite.
    var remove: (URL) -> Void
    /// Eject a volume.
    var eject: (SidebarVolume) -> Void
    /// Items were dropped onto a row's folder (Option / Command held as given).
    var drop: (_ urls: [URL], _ folder: URL, _ option: Bool, _ command: Bool) -> Void
}
