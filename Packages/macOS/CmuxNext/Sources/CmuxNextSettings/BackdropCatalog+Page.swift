public import CmuxNextDesign

public extension BackdropCatalog {
    /// The Settings page's wallpaper grid rows. Each carries its picker collection (an art
    /// collection, "Your images", "Apple Wallpapers", Moving wallpapers), and the page groups the
    /// grid by it; a video says so, and a macOS still whether its full picture is downloaded.
    var pageRows: JSONValue {
        .array(choices.map { choice -> JSONValue in
            let title = choice.title(aerialNames: aerialNames)
            var row: [String: JSONValue] = ["id": .string(choice.id), "title": .string(title),
                                            "attribution": .string(choice.attribution(title: title))]
            if let collection = choice.pickerCollection {
                row["collection"] = .string(collection.id)
                row["collection_title"] = .string(collection.title)
            }
            if choice.isVideo {
                row["video"] = .bool(true)
                // An aerial macOS lists but has not downloaded: a cloud tile that opens the Wallpaper pane.
                if case .system(let path) = choice, pendingVideoPaths.contains(path) { row["downloaded"] = .bool(false) }
            } else if case .system(let path) = choice {
                row["downloaded"] = .bool(appleWallpapers[path]?.isDownloaded ?? true)
            }
            return .object(row)
        })
    }
}

/// Memoizes the settings-page projection of a catalog. Host-list reads are
/// observation tracked and can run for unrelated settings changes; rebuilding
/// every wallpaper label on each read was a sizeable idle cost.
public struct BackdropCatalogPageRowsCache: Sendable {
    private var catalog: BackdropCatalog?
    private var cached: JSONValue?
    /// Number of projections built; useful to assert the cache's stop condition.
    public private(set) var builds = 0

    public init() {}

    public mutating func rows(for catalog: BackdropCatalog) -> JSONValue {
        if self.catalog != catalog {
            self.catalog = catalog
            cached = catalog.pageRows
            builds += 1
        }
        return cached ?? .array([])
    }
}
