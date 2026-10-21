import Foundation
public import ImageIO

/// The appearance a backdrop is drawn for. A dynamic macOS wallpaper has a picture for each: a
/// light and dark pair, or a day of sun positions, where the highest sun reads as light and the
/// lowest as dark.
public nonisolated enum BackdropAppearance: String, Hashable, Sendable {
    case light
    case dark

    /// The frame of a dynamic HEIC for this appearance, read from its `apple_desktop` metadata
    /// (`apr` light/dark pairs, `solar` and `h24` sun or time sequences); 0 for any other image.
    public func frame(in source: CGImageSource) -> Int {
        guard CGImageSourceGetCount(source) > 1, let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return 0 }
        let count = CGImageSourceGetCount(source)
        for name in ["apple_desktop:apr", "apple_desktop:solar", "apple_desktop:h24"] {
            guard let plist = Self.plist(name, in: metadata) else { continue }
            // Every format names its light and dark frames under `ap` (`apr` at its top level).
            let pair = (plist["ap"] as? [String: Any]) ?? plist
            if let index = pair[self == .dark ? "d" : "l"] as? Int, index >= 0, index < count { return index }
            // Older solar pictures only list sun positions: altitude `a` for frame `i`.
            let positions = (plist["si"] as? [[String: Any]] ?? []).compactMap { entry -> (altitude: Double, index: Int)? in
                guard let altitude = (entry["a"] as? NSNumber)?.doubleValue, let index = entry["i"] as? Int, index >= 0, index < count
                else { return nil }
                return (altitude, index)
            }
            let pick = self == .dark ? positions.min { $0.altitude < $1.altitude } : positions.max { $0.altitude < $1.altitude }
            if let pick { return pick.index }
        }
        return 0
    }

    private static func plist(_ path: String, in metadata: CGImageMetadata) -> [String: Any]? {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
              let value = CGImageMetadataTagCopyValue(tag) as? String, let data = Data(base64Encoded: value) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}
