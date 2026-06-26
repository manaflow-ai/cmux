public import Foundation

/// A uniquely-named output location for a debug screenshot or panel snapshot,
/// living under the shared `cmux-screenshots` directory inside the system
/// temporary directory.
///
/// Deriving a `ScreenshotDestination` produces a fresh ISO8601-timestamp plus
/// short-UUID identifier and the destination `.png` file URL. The caller is
/// responsible for creating `directory` on disk and encoding the image to
/// `fileURL`; this type performs no I/O.
public struct ScreenshotDestination: Sendable {
    /// Timestamp-and-short-UUID identifier, with `:`/`+` replaced so it is a
    /// valid path component (e.g. `2026-06-26T05-52-00Z_1a2b3c4d`).
    public let id: String
    /// The `cmux-screenshots` directory under the system temporary directory.
    public let directory: URL
    /// The destination `.png` file URL inside `directory`, prefixed by `label`
    /// when the label is non-empty.
    public let fileURL: URL

    /// Derives a fresh destination. When `label` is non-empty it prefixes the
    /// filename as `<label>_<id>.png`; otherwise the filename is `<id>.png`.
    public init(label: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "_")
        let shortId = UUID().uuidString.prefix(8)
        let id = "\(timestamp)_\(shortId)"
        self.id = id

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-screenshots")
        self.directory = directory

        let filename = label.isEmpty ? "\(id).png" : "\(label)_\(id).png"
        self.fileURL = directory.appendingPathComponent(filename)
    }
}
