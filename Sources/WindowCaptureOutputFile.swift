import Foundation

/// How a capture writes the file the caller asked for.
///
/// A recording and a still both write somewhere else first and move the result
/// into place when it is complete, so an interrupted, failed or killed capture
/// never leaves a truncated file at the caller's path, and whatever was there
/// before survives until there is something to replace it with. Shared so the
/// two cannot disagree about what they may overwrite.
enum WindowCaptureOutputFile {
    /// A hidden sibling of the output, named after the capture so two captures
    /// and a stale leftover cannot be confused for each other.
    static func workingURL(for outputURL: URL, discriminator: String) -> URL {
        outputURL.deletingLastPathComponent().appendingPathComponent(
            ".\(outputURL.lastPathComponent).\(discriminator).partial"
        )
    }

    /// Whether cmux may put a file at this path.
    ///
    /// Nothing there is fine, and so is a file or a symlink the caller chose. A
    /// directory, socket, fifo or device is not something a capture gets to
    /// delete on the caller's behalf.
    static func isReplaceable(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return true
        }
        return type == .typeRegular || type == .typeSymbolicLink
    }

    /// Creates the output's directory and clears any leftover working file.
    static func prepare(outputURL: URL, workingURL: URL) throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: workingURL)
    }

    /// Moves the finished capture to the path the caller asked for.
    static func promote(from workingURL: URL, to outputURL: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: outputURL.path) {
            _ = try manager.replaceItemAt(outputURL, withItemAt: workingURL)
        } else {
            try manager.moveItem(at: workingURL, to: outputURL)
        }
    }
}
