public import Foundation
import CmuxNextCompat

/// Reads the reference captures the Density Overlay Playground lays over cmux's browser chrome, off the main thread,
/// through the checked file seams. Pure reads; nothing is written.
public nonisolated struct BrowserChromeReferenceFiles: Sendable {
    /// Makes the reader.
    public init() {}

    /// The PNG files in `directory`, by name; none when it is missing (a fleet build has no checkout).
    public func pngs(in directory: URL) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            ((try? FileManager.checked.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "png" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }.value
    }

    /// The bytes of the image at `url`, or nil when it cannot be read.
    public func data(at url: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) { try? Data(blockingContentsOf: url) }.value
    }
}
