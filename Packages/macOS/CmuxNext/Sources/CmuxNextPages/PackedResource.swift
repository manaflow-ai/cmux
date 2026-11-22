public import Foundation
import CmuxNextCompat

/// A bundled file the app build may store packed (CMUX-570, app size): the markdown viewer's diagram
/// libraries (Mermaid, Ondine, Vega) run only when a page draws a diagram or a chart, so the
/// "Pack markdown-viewer libraries" phase replaces each `<name>` with `<name>.xz` (LZMA2 in the xz
/// container, scripts/cmux-next/pack-markdown-libraries.py), 6.4 MB down to 1.6 MB. The first read
/// unpacks one into ``cache`` and later reads take it from there, so the files still ship in the
/// app, work offline and from the first use. A folder that holds the file itself (the repository's,
/// a build that did not pack) is read as before.
///
/// The system's Compression framework reads xz (`NSData.decompressed(using: .lzma)`): no decoder of
/// our own in the app.
public nonisolated struct PackedResource: Sendable {
    /// The packed copy's extension.
    public static let suffix = "xz"

    /// Where unpacked files are kept; nil unpacks on every read and keeps nothing.
    public let cache: URL?

    public init(cache: URL?) {
        self.cache = cache
    }

    /// The app's: `~/Library/Caches/<bundle id>/packed-resources` (a DEV build's bundle id is its own).
    public static let app = PackedResource(
        cache: BuildStatePaths.current.caches
            .appending(path: Bundle.main.bundleIdentifier ?? "cmux-next", directoryHint: .isDirectory)
            .appending(path: "packed-resources", directoryHint: .isDirectory))

    /// `url`'s packed copy, `<url>.xz`.
    public static func packed(_ url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: url.lastPathComponent + "." + suffix)
    }

    /// Whether `url` or its packed copy exists.
    public func exists(_ url: URL) -> Bool {
        let files = FileManager.default
        return files.fileExists(atPath: url.path) || files.fileExists(atPath: Self.packed(url).path)
    }

    /// `url`'s bytes: the file itself when it exists, else its packed copy unpacked (from ``cache``
    /// after the first read); nil when neither can be read.
    public func data(_ url: URL) -> Data? {
        if let data = try? Data(contentsOf: url) { return data }
        let packed = Self.packed(url)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: packed.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        // Keyed by the packed copy's size and time: an app update brings new files and new names,
        // and two app copies on one Mac never read each other's.
        let stamp = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let kept = cache?.appending(path: "\(url.lastPathComponent)-\(size.int64Value)-\(Int64(stamp * 1000))")
        if let kept, let data = try? Data(contentsOf: kept) { return data }
        guard let bytes = try? Data(contentsOf: packed),
              let data = try? (bytes as NSData).decompressed(using: .lzma) as Data else { return nil }
        if let cache, let kept {
            // Atomic: a read never sees half a file; a failed write only means unpacking again next time.
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? data.write(to: kept, options: .atomic)
        }
        return data
    }
}
