public import CmuxNextDesign

public extension BackdropCatalog {
    /// The Settings page's wallpaper grid rows. Art carries its picker collection (Dark Art, Museum
    /// Icons, Calm, Doré), the person's own images theirs ("Your images") and macOS wallpapers
    /// "Apple Wallpapers", with whether the full picture is downloaded; the page groups the grid
    /// by collection.
    var pageRows: JSONValue {
        .array(choices.map { choice -> JSONValue in
            var row: [String: JSONValue] = ["id": .string(choice.id), "title": .string(choice.title),
                                            "attribution": .string(choice.attribution)]
            switch choice {
            case .art(let art):
                row["collection"] = .string(art.collection.rawValue)
                row["collection_title"] = .string(art.collection.title)
            case .file:
                row["collection"] = .string(BackdropUserImages.collection)
                row["collection_title"] = .string(BackdropUserImages.collectionTitle)
            case .system(let path):
                row["collection"] = .string(AppleWallpapers.collection)
                row["collection_title"] = .string(AppleWallpapers.collectionTitle)
                row["downloaded"] = .bool(appleWallpapers[path]?.isDownloaded ?? true)
            case .desktop:
                break
            }
            return .object(row)
        })
    }
}
