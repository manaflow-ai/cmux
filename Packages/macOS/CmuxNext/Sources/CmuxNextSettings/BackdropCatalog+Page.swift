public import CmuxNextDesign

public extension BackdropCatalog {
    /// The Settings page's wallpaper grid rows. Each carries its picker collection (an art
    /// collection, "Your images", "Apple Wallpapers", Moving wallpapers), and the page groups the
    /// grid by it; a video says so, and a macOS still whether its full picture is downloaded.
    var pageRows: JSONValue {
        .array(choices.map { choice -> JSONValue in
            var row: [String: JSONValue] = ["id": .string(choice.id), "title": .string(choice.title),
                                            "attribution": .string(choice.attribution)]
            if let collection = choice.pickerCollection {
                row["collection"] = .string(collection.id)
                row["collection_title"] = .string(collection.title)
            }
            if choice.isVideo {
                row["video"] = .bool(true)
                // An aerial macOS lists but has not downloaded: a cloud tile that opens the Wallpaper pane.
                if case .system(let path) = choice, AppleWallpapers.isPending(path) { row["downloaded"] = .bool(false) }
            } else if case .system(let path) = choice {
                row["downloaded"] = .bool(appleWallpapers[path]?.isDownloaded ?? true)
            }
            return .object(row)
        })
    }
}
