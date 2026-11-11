import AppKit
import CmuxNextCompat
import ImageIO

/// The pixel size of each image and movie a drop, paste or pick brings in, told to the page as the
/// gesture goes to it, so its chip draws at its final shape at once (Leo, 2026-11-11: "attachments
/// should be faster? if you're literally just pointing to a file path, why would it ever take time to
/// load anything anyways?"). Read from each file's header only (ImageIO's properties, no decode, no
/// cache), off the main thread. The script sets `window.__cmuxAttachShapes` and fires
/// `cmux-attach-shapes`: the page takes it in the gesture's own task when it is there first, or on the
/// event while its tiles wait unseen for their shape (composer/attachmentIntakeModel.ts `hostShapes`,
/// `onHostShapes`). Without it (an older host) the page reads each header itself.
nonisolated enum AgentPaneGestureShapes {
    /// At most this many files are measured: a drop of a whole folder's images reads its headers
    /// in the page as before.
    static let maxFiles = 16

    struct Shape: Encodable, Equatable, Sendable {
        /// WebKit's `File.name` for the file (its URL's last component); nil for a pasted bitmap with
        /// no file, which the page matches to the paste's only image.
        let name: String?
        let width: Int
        let height: Int
    }

    /// Movie files whose picture size is read from their track header (``videoSize(_:)``).
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// `urls`' image and video sizes, oriented as they are displayed; other files, unreadable ones,
    /// and files whose header read could stall give none: on a volume that is not local, or in iCloud
    /// Drive or a File Provider folder and not downloaded (its first read fetches the whole file).
    static func shapes(of urls: [URL]) -> [Shape] {
        urls.prefix(maxFiles).compactMap { url in
            guard url.isFileURL, isHere(url) else { return nil }
            if videoExtensions.contains(url.pathExtension.lowercased()) {
                return videoSize(url).map { Shape(name: url.lastPathComponent, width: $0.width, height: $0.height) }
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { return nil }
            return shape(of: source, name: url.lastPathComponent)
        }
    }

    /// Whether `url`'s bytes are on this Mac now: on a local volume, and downloaded when it is a cloud file.
    static func isHere(_ url: URL) -> Bool {
        guard let values = try? url.blockingResourceValues(
            forKeys: [.volumeIsLocalKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        else { return false }
        if values.volumeIsLocal == false { return false }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current { return false }
        return true
    }

    /// A QuickTime or MP4 movie's picture size from its first picture track's header (`tkhd`), turned
    /// by its matrix, wherever its `moov` is (a screen recording writes it after its media): a few
    /// 16-byte box headers and one small box read, never the media. The page's own read
    /// (composer/videoShape.ts `videoHeaderSize`) is the same.
    static func videoSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        func read(_ at: UInt64, _ count: Int) -> Data? {
            guard (try? handle.seek(toOffset: at)) != nil, let data = try? handle.read(upToCount: count) else { return nil }
            return data
        }
        func boxes(_ start: UInt64, _ end: UInt64) -> [(type: String, body: UInt64, end: UInt64)] {
            var found: [(String, UInt64, UInt64)] = [], at = start
            while at + 8 <= end, found.count < 64, let head = read(at, 16), head.count >= 8 {
                let bytes = [UInt8](head)
                var size = bytes[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                var body = at + 8
                if size == 1 {
                    guard bytes.count >= 16 else { break }
                    size = bytes[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                    body = at + 16
                } else if size == 0 {
                    size = end - at
                }
                guard size >= body - at, at + size <= end else { break }
                found.append((String(decoding: bytes[4..<8], as: UTF8.self), body, at + size))
                at += size
            }
            return found
        }
        for top in boxes(0, end) where top.type == "moov" {
            for trak in boxes(top.body, top.end) where trak.type == "trak" {
                guard let tkhd = boxes(trak.body, trak.end).first(where: { $0.type == "tkhd" }),
                      let data = read(tkhd.body, Int(min(UInt64(64 * 1024), tkhd.end - tkhd.body)))
                else { continue }
                let bytes = [UInt8](data)
                guard let version = bytes.first else { continue }
                let matrix = version == 1 ? 52 : 40
                guard bytes.count >= matrix + 44 else { continue }
                func u32(_ at: Int) -> UInt32 { bytes[at..<at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
                let width = Double(u32(matrix + 36)) / 65536, height = Double(u32(matrix + 40)) / 65536
                guard width > 0, height > 0 else { continue }
                // a and b of the matrix (16.16): a quarter turn has a = 0.
                let turned = Int32(bitPattern: u32(matrix)) == 0 && Int32(bitPattern: u32(matrix + 4)) != 0
                let (w, h) = (Int(width.rounded()), Int(height.rounded()))
                return turned ? (h, w) : (w, h)
            }
            return nil
        }
        return nil
    }

    /// The bitmap a paste with no file carries (a screenshot copied to the clipboard): its bytes, read
    /// once on the main thread (the pasteboard is AppKit's), and whether they are a PNG.
    @MainActor static func pastedBitmap(on pasteboard: NSPasteboard) -> (data: Data, png: Bool)? {
        // Text copied from a spreadsheet, slide or document carries a picture of itself too: that
        // paste is the text, and its picture is never drawn or written.
        if pasteboard.availableType(from: [.string, .rtf, .html]) != nil { return nil }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type) else { continue }
            return (data, type == .png)
        }
        return nil
    }

    /// A pasted bitmap's size from its bytes' header.
    static func bitmapShape(_ data: Data) -> Shape? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
            .flatMap { shape(of: $0, name: nil) }
    }

    static func shape(of source: CGImageSource, name: String?) -> Shape? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
            as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { return nil }
        // EXIF orientations 5 to 8 turn the picture a quarter: it shows height by width.
        let turned = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        return turned ? Shape(name: name, width: height, height: width) : Shape(name: name, width: width, height: height)
    }

    /// The script that hands `shapes` of a `kind` gesture to the page; nil when there are none.
    /// `at`: when the gesture happened (ms since 1970), so the page keeps it only for that gesture.
    static func script(_ shapes: [Shape], kind: AgentPaneDroppedPaths.Kind, at: Double) -> String? {
        guard !shapes.isEmpty else { return nil }
        struct Told: Encodable {
            let kind: String
            let at: Double
            let shapes: [Shape]
        }
        let told = Told(kind: kind.rawValue, at: at, shapes: shapes)
        guard let data = try? JSONEncoder().encode(told), let json = String(data: data, encoding: .utf8) else { return nil }
        return "window.__cmuxAttachShapes = \(json); window.dispatchEvent(new Event('cmux-attach-shapes'));"
    }
}
