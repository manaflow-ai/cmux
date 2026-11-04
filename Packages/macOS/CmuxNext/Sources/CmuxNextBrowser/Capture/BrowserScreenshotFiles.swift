public import CmuxNextCompat
public import CoreGraphics
public import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes and stores browser captures off the main actor, with bounded retention.
public nonisolated struct BrowserScreenshotFiles: Sendable {
    private let directory: URL
    private let manager: CheckedFileManager
    private let keeping: Int
    private let lifetime: TimeInterval

    /// The caller chooses the output directory and file manager; defaults preserve capture retention.
    public init(directory: URL, manager: CheckedFileManager = CheckedFileManager(), keeping: Int = 32, lifetime: TimeInterval = 3600) {
        self.directory = directory
        self.manager = manager
        self.keeping = keeping
        self.lifetime = lifetime
    }

    /// Off the main actor: up to 4 MiB of PNG grows to 5.3 MiB of text.
    @concurrent
    public func base64(_ data: Data) async -> String { data.base64EncodedString() }

    /// The part of a viewport snapshot `clip` covers (CSS px scaled to the
    /// snapshot's pixels).
    public func crop(_ image: CGImage, rect: CGRect, viewport: CGSize) -> CGImage? {
        let scaleX = Double(image.width) / Double(viewport.width)
        let scaleY = Double(image.height) / Double(viewport.height)
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else {
            return nil
        }
        let rect = CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX, height: rect.height * scaleY)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isEmpty, let cropped = image.cropping(to: rect) else {
            return nil
        }
        return cropped
    }

    /// Encodes off the main actor: a full page can be many megapixels.
    @concurrent
    public func pngData(_ image: CGImage) async -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Writes off the main actor to `$TMPDIR/cmux-browser-screenshots/`.
    @concurrent
    public func save(_ png: Data, tabID: String) async throws -> String {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let file = directory.appendingPathComponent("\(tabID)-\(stamp)-\(UUID().uuidString.prefix(8)).png")
        try png.write(to: file, options: .atomic)
        prune(directory, keeping: keeping, newerThan: Date().addingTimeInterval(-lifetime))
        return file.path
    }

    /// Deletes the PNGs in `directory` past the newest `keeping`, and any
    /// modified before `cutoff`. Best effort: a file another save is
    /// writing or a reader holds open is left for the next prune.
    private func prune(_ directory: URL, keeping: Int, newerThan cutoff: Date) {
        let manager = manager
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                           options: [.skipsHiddenFiles]) else { return }
        let dated = files.filter { $0.pathExtension == "png" }.map { file in
            (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (index, (file, modified)) in dated.enumerated() where index >= keeping || modified < cutoff {
            try? manager.removeItem(at: file)
        }
    }
}
