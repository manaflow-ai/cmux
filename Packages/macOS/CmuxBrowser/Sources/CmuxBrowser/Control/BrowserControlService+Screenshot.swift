public import AppKit
import Foundation

/// PNG encoding and temp-file persistence for the `browser.screenshot` control
/// command.
///
/// Every byte produced here is identical to what the former
/// `v2BrowserScreenshot(params:)` body assembled inline in `TerminalController`:
/// the TIFF-via-`NSBitmapImageRep` PNG encode, the
/// `cmux-browser-screenshots` temp directory, the
/// `surface-<short-id>-<timestampMs>-<short-random>.png` filename, the atomic
/// write, and the keep-most-recent-50 / 24h prune policy. Only the stateless
/// assembly moved off the controller; the owning `@MainActor` controller keeps
/// the WebKit `captureAutomationVisibleViewportSnapshot` seam, the bounded
/// blocking await, and the per-surface workspace/surface identity it folds into
/// the RPC reply, so the wire output is unchanged.
extension BrowserControlService {
    /// Encodes an `NSImage` as PNG `Data`, byte-identical to the former
    /// `v2PNGData(from:)`.
    ///
    /// Renders the image's TIFF representation through `NSBitmapImageRep` and
    /// asks for a `.png` representation; returns `nil` when either step fails.
    /// - Parameter image: the captured viewport snapshot.
    /// - Returns: PNG-encoded data, or `nil` if encoding fails.
    public func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Best-effort persists the screenshot bytes to the shared
    /// `cmux-browser-screenshots` temp directory and returns the resulting paths.
    ///
    /// Byte-identical to the former inline persistence in `v2BrowserScreenshot`:
    /// it creates the directory (with intermediate directories), prunes stale
    /// captures, composes the `surface-<short-id>-<timestampMs>-<short-random>.png`
    /// filename from the surface UUID prefix, the current millisecond timestamp,
    /// and a fresh random UUID prefix, then writes atomically. On any failure the
    /// corresponding path is left `nil` so the caller can still return the
    /// base64 payload. The temp directory and timestamp/random sources are not
    /// injected, matching the original which read them directly, so the persisted
    /// location is unchanged.
    /// - Parameters:
    ///   - imageData: the PNG bytes to persist.
    ///   - surfaceId: the browser surface the capture came from; its UUID prefix
    ///     seeds the filename.
    /// - Returns: the absolute file path and `file://` URL string when the write
    ///   succeeded, otherwise `nil` for each.
    public func persistScreenshot(
        imageData: Data,
        surfaceId: UUID
    ) -> BrowserScreenshotPersistence {
        var filePath: String?
        var fileURL: String?
        let screenshotsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-screenshots", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)) != nil {
            pruneTemporaryFiles(in: screenshotsDirectory)
            let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
            let shortSurfaceId = String(surfaceId.uuidString.prefix(8))
            let shortRandomId = String(UUID().uuidString.prefix(8))
            let filename = "surface-\(shortSurfaceId)-\(timestampMs)-\(shortRandomId).png"
            let imageURL = screenshotsDirectory.appendingPathComponent(filename, isDirectory: false)
            if (try? imageData.write(to: imageURL, options: .atomic)) != nil {
                filePath = imageURL.path
                fileURL = imageURL.absoluteString
            }
        }
        return BrowserScreenshotPersistence(filePath: filePath, fileURL: fileURL)
    }

    /// Prunes a temp directory to the most recent `maxCount` regular files, also
    /// removing anything older than `maxAge`. Byte-identical to the former
    /// `bestEffortPruneTemporaryFiles(in:keepingMostRecent:maxAge:)`.
    ///
    /// Enumerates regular files with their modification/creation dates, sorts
    /// newest-first, and removes any entry past the count cap or the age cap. All
    /// I/O is best-effort: a failed enumeration returns early and a failed removal
    /// is ignored, so callers never observe a thrown error.
    /// - Parameters:
    ///   - directoryURL: the directory to prune.
    ///   - maxCount: how many newest files to keep (default 50).
    ///   - maxAge: maximum age in seconds before a file is removed regardless of
    ///     count (default 24 hours).
    func pruneTemporaryFiles(
        in directoryURL: URL,
        keepingMostRecent maxCount: Int = 50,
        maxAge: TimeInterval = 24 * 60 * 60
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let datedEntries = entries.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in datedEntries.enumerated() {
            if index >= maxCount || now.timeIntervalSince(entry.date) > maxAge {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }
}
